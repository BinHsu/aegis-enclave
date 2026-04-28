# ADR-0035: Bootstrap ECS task runs both schema migration and cache seeding (case-study scope; greenfield drops schema migration per ADR-0042)

## Status
**Accepted (2026-04-26) for the case-study deliverable scope** (`main` branch — bootstrap task carries `Base.metadata.create_all` for the PG executions table + Valkey cache seed).
**Superseded by ADR-0042 for greenfield production deployments (2026-04-28)** — DynamoDB tables are terraform-managed (`aws_dynamodb_table.executions` resource); there is no schema-migration step in the greenfield target. The bootstrap task's role narrows to cache pre-warm only on the `pivot/dynamodb-multi-region` branch. The driver-fragility argument ("`null_resource` is brittle") in this ADR's Reconsidered block remains correct for both branches; in the greenfield branch it applies to the cache-seed-only bootstrap, in the case-study branch it applies to schema+cache-seed.

The ADR body below records the original case-study rationale as historical truth and remains accurate for `main` branch.

## Context

The deployment sequence for `aegis-enclave` has two initialisation concerns that must complete before the API and worker services receive traffic:

1. **RDS schema initialisation** — the `executions` table must exist before the API or worker can write audit rows.
2. **Valkey cache seeding** — the bootstrap pre-warm (`[1, 100_000]`) should be present before the first worker request to maximise cache-hit rate from cold start.

ADR-0031 specified a one-shot bootstrap ECS task (`cache_bootstrap`) triggered by a Terraform `null_resource`. At the time ADR-0031 was written, schema initialisation was expected to be handled separately (either by the application at startup, or by a dedicated migration mechanism).

During Phase 2.5 cloud-acceptance, a concrete problem surfaced: on first apply, the `executions` table did not exist when the API ECS task first started, causing the `/health` endpoint's `SELECT 1` to pass but the first `POST /primes` to fail on INSERT. The root cause is that RDS Multi-AZ initialisation completes before ECS task startup, but the schema DDL is never run automatically — there is no equivalent of Django's `migrate` or a Flyway auto-run in the FastAPI application lifecycle.

Three strategies were evaluated:

| Strategy | Description | Verdict |
|---|---|---|
| **A — Separate `db_migrate` ECS task** | A dedicated one-shot ECS task definition triggered by its own `null_resource`, runs only `Base.metadata.create_all` | Canonical separation of concerns; more files, more null_resources, more Terraform output wiring |
| **B — SQLAlchemy `create_all` in FastAPI lifespan** | Add `await Base.metadata.create_all(engine)` to the FastAPI `@asynccontextmanager lifespan` block | One-line code change; but creates a startup-time race (multiple replicas race to call `create_all` simultaneously on cold start) and makes schema migration harder to gate independently of traffic |
| **C — Extend `cache_bootstrap` to also run schema migration** | The existing bootstrap ECS task (`bootstrap.py`) calls `Base.metadata.create_all(engine)` before the Valkey seeding loop | No new task definitions; no new null_resources; sequencing already correct (bootstrap completes before ECS services reach steady state via `depends_on`) |

Strategy C was chosen. The bootstrap task already: (a) has the correct IAM permissions to reach RDS (app task role), (b) has the correct network placement (private subnets), (c) has Secrets Manager access for the RDS password, and (d) is triggered before the app and worker services are unblocked by the Terraform `depends_on` chain.

The idempotency property is preserved: `Base.metadata.create_all` is a no-op if the tables already exist (`CREATE TABLE IF NOT EXISTS` semantics). Running the bootstrap task twice produces `schema_ensured` on both invocations with no side effects.

## Decision

The `cache_bootstrap` ECS task (`src/prime_service/bootstrap.py`) is extended to run **both** RDS schema migration (`Base.metadata.create_all`) **and** Valkey cache seeding (`[1, 100_000]`), in that order.

The task sequence is:

1. Connect to RDS via the same credentials the worker uses (Secrets Manager `valueFrom` injection).
2. Call `Base.metadata.create_all(engine)` — creates `executions` table if absent; no-op if present. Log `schema_ensured`.
3. Connect to Valkey.
4. Check whether the seed range `[1, 100_000]` is already present (ZCARD on the prime ZSET key).
5. If absent: compute primes in `[1, 100_000]` via the sieve, write to Valkey ZSET. Log `bootstrap_done`.
6. If present: skip. Log `bootstrap_skip already_cached`.
7. Exit 0.

The Terraform `null_resource` trigger and `depends_on` wiring remain unchanged — the bootstrap task already depends on the ECS cluster, RDS, and Valkey being ready.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **Separate `db_migrate` ECS task (Strategy A)** | Canonical but adds a second task definition, a second `null_resource`, additional IAM/network config, and a second place to wire `depends_on`. For a PoC deployment with one schema file, the overhead exceeds the separation-of-concerns benefit. The same discipline can be introduced in a production adoption without architectural rework. |
| **Alembic migration framework** | Proper production migration tool with version tracking, rollback, and branching support. Adds a dependency (`alembic`), a `migrations/` directory, and an `env.py` configuration file. Out of scope for PoC calibration (ADR-0003); `Base.metadata.create_all` is sufficient when the schema has no existing production state to migrate through. |
| **SQLAlchemy `create_all` in FastAPI lifespan (Strategy B)** | Simpler code change (one line in `main.py`), but: (a) multiple replicas race to call `create_all` on cold start — SQLAlchemy's `IF NOT EXISTS` semantics make this safe in practice, but the concurrent DDL execution is undesirable; (b) schema migration is coupled to traffic-serving startup, making it harder to gate, monitor, or retry independently; (c) any schema error blocks the API service, not a dedicated migration task where a failure is immediately diagnosable. |
| **No schema migration (rely on db/init.sql at RDS creation)** | RDS module does not support `init.sql` execution at provision time. A `db/init.sql` file could be run as a provisioner, but Terraform provisioners are explicitly deprecated for this use case and run with no retry semantics. |

## Consequences

- `src/prime_service/bootstrap.py` imports `Base` and `engine` from `db.py` and calls `create_all` at the top of `main()`.
- The bootstrap CloudWatch log stream is the authoritative record of schema initialisation; `schema_ensured` in the logs confirms the table exists before any API traffic.
- Tests for `bootstrap.py` are updated to mock the `create_all` call alongside the existing Valkey mock. Idempotency tests cover the case where `create_all` is called with an already-existing schema (verifies no exception is raised).
- A production adoption that requires incremental schema migrations (ALTER TABLE, column additions, data migrations) must replace `create_all` with Alembic or an equivalent migration framework at that point. The `create_all` approach is explicitly bounded to a greenfield schema with no existing production state.
- The bootstrap task's IAM task role must include `rds-db:connect` permission (already present for the worker's DB access) — no new IAM changes required.

### Reconsidered in Phase 2.5 (2026-04-26): why we are not splitting now

After this ADR was first written we revisited Strategy A ("split into separate `db_migrate` ECS task") at the end of the Phase 2.5 cycle, expecting to file the split as paid technical debt. The deeper conclusion was that splitting is the wrong scope cut by itself: the actual fragility in the bootstrap path is the **driver** — a Terraform `null_resource` with `local-exec → aws ecs run-task → poll completion`. That driver is brittle (dependent on the operator's local AWS CLI, no retry semantics, no timeout escape hatch, sequencing only via `depends_on`). Splitting the task without replacing the driver doubles the number of `null_resource`-fired one-shot invocations (one for `db_migrate`, one for `cache_bootstrap`, with the second `depends_on` the first), increasing the fragile surface for no architectural clarity gain — the same `null_resource` weakness exists, just twice.

The right V2 cut is therefore **driver + split together**: replace `null_resource` with a proper job runner (Step Functions orchestrating two ECS task invocations, or a CodePipeline migration stage gated by the GHA workflow added in P1, or an Alembic CLI invocation as a CI step running before `terraform apply` of the ECS service module), then split the bootstrap into `db_migrate` + `cache_bootstrap` with the new runner sequencing them. Doing the split alone (without replacing the driver) trades one PoC expedient (combined task) for a worse one (two combined tasks behind the same fragile driver).

This insight is recorded here rather than in a new ADR because the original decision (Strategy C) stands; what changed is the V2 exit criterion. The bullet above ("production adoption that requires incremental schema migrations must replace `create_all` with Alembic") is now refined: such an adoption must replace **both** `create_all` and the `null_resource` driver — the migration framework choice and the orchestration mechanism are coupled.

## Related ADRs
- ADR-0029 (async POST + SQS + worker pool — the architecture the bootstrap task initialises for)
- ADR-0031 (Valkey + ZSET + Lua range-coalescing — the original bootstrap task specification; this ADR extends it)
- ADR-0033 (async drain semantics — worker relies on the schema being present; bootstrap task ensures this before worker receives traffic)
- ADR-0003 (PoC scope, prod hygiene calibration — the `create_all` approach is explicitly bounded to PoC scope)
