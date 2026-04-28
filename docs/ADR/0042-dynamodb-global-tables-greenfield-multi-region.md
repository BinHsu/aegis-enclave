# ADR-0042: DynamoDB Global Tables active-active is the greenfield multi-region production target

## Status
Accepted (2026-04-28) — **canonical greenfield production target.**

**Supersedes ADR-0040 for greenfield deployments**. ADR-0040 is retained as the Aurora migration path for forkers carrying an existing PostgreSQL/RDS investment.

This ADR is **not implemented in the case-study cycle**. The case-study deliverable ships single-region eu-central-1 per ADR-0007 (3-AZ posture per ADR-0007 reconsidered) with RDS PostgreSQL Multi-AZ per ADR-0009. ADR-0042 documents the cloud-native architectural target a forker should pick when starting greenfield, **not** when migrating from an existing PG investment.

## Context

### Phase 1 architectural clarification

The case-study deliverable's data layer was Phase 1 committed to RDS PostgreSQL Multi-AZ (ADR-0009). At the time, the choice was made on the assumption that the case-study brief mandated a relational data model. **A subsequent re-reading of the brief showed it is engine-agnostic** — there is no "must use PostgreSQL" or "must use SQL" constraint. PG was therefore our judgment, not a brief mandate.

For a greenfield deployment of the same workload — without the Phase 1 PG schema commitment + SQLAlchemy tooling + 50+ tests already shaped against an ORM — the cloud-native production-grade choice is materially different.

### Workload classification

The aegis-enclave workload is an **audit log + idempotency-checked write + range query by created_at** shape:

| Workload property | aegis-enclave | Implication |
|---|---|---|
| Write pattern | Insert-mostly (audit row per request); rare update for status transitions (queued → running → done) | DynamoDB-shaped; no JOIN-heavy queries |
| Read pattern | By `execution_id` (poll endpoint); occasional time-range scan (worker stale-running detection); no transactional cross-row reads | Single-table model with optional GSI on time/status |
| Foreign keys | None load-bearing (audit table is append-only; no tenant/user FK to enforce) | DynamoDB single-table fits |
| ACID requirements | Single-item conditional writes for idempotency | DynamoDB conditional expressions native support this |
| PII / regulated data | None for the prime-computation workload itself | No GDPR-driven retention complexity beyond audit-log baseline |
| Scale curve | Burst 50–100 RPS for ≤ 30s, idle baseline ~1 req/min (per design_doc § 4.1) | Both DynamoDB on-demand and provisioned modes fit; on-demand simpler |

This is a textbook **cloud-native NoSQL audit log** workload. SQL was not the wrong technical choice for Phase 1 (it works correctly), but it was a mismatched architectural choice: the relational features (JOIN, transactions across rows, schema migration discipline) the team is paying for are not features the workload uses.

### Workload tier and RTO calibration

Per the workload-tier framework recorded in memory `feedback_workload_tier_classification.md`:

| Tier | Type | Industry-acceptable RTO | aegis-enclave fit? |
|---|---|---|---|
| 0 | Mission-critical real-time control (launch ops, TT&C) | < 1s control loops | ❌ — not on generic cloud anyway |
| 1 | Customer-facing prod | 5–15 min | ❌ |
| 2 | Operations support (planning, audit, post-flight) | 1–4 hours | ✅ aegis-enclave fits here |
| 3 | Analytics / back-office | 24+ hours | ❌ (more critical than this) |

ADR-0008 RTO target is 15 min — which is conservative for Tier 2 (industry baseline 1-4h). Multi-region pushes RTO lower still, but **Tier 2 does not require multi-region by industry convention**. Multi-region is a quality-of-engineering signal, not a compliance mandate, for this workload class.

Greenfield architectural recommendation is therefore: **build for the right shape, even if the shape's full RTO budget isn't required**. DynamoDB Global Tables active-active is the right shape because it fits the workload + scales the RTO floor without proportional operational complexity. Aurora Global active-passive achieves comparable functional outcomes but with operational complexity that does scale (Lambda glue, Path 1/2 failback, reconstitution windows — see ADR-0040 for the full record of that complexity).

### Why active-active over active-passive

DynamoDB Global Tables is **multi-master** — every region accepts writes natively, with last-writer-wins conflict resolution at the cell level and ~1 second cross-region replication lag. Operating it as **active-active** (both regions serving traffic via Route53 weighted routing) rather than active-passive is the architecturally honest choice:

- Multi-master is the design's purpose; running it active-passive throws away half the value
- Active-active distributes load naturally across regions (closer-region operators get lower latency)
- "Failover" reduces to "flip Route53 weight to 100/0" — no Aurora-style promotion step
- Cost is identical (both regions provisioned in either case); only routing changes

Active-passive (Frankfurt primary, Ireland standby with desired_count=1) makes sense **only** when secondary-region workload startup latency (cold start of ECS tasks) matters less than steady-state cost. For our workload with `worker_min_count = 3` already low, the marginal saving of active-passive is minimal and the failover semantics are worse.

## Decision

The greenfield production target is **DynamoDB Global Tables active-active** with the following composition:

### Data layer

- `aws_dynamodb_table.executions` with `replica` configurations for `eu-central-1` and `eu-west-1`
- **Primary key**: `execution_id` (String, UUID4 generated by the API on insert) — DynamoDB has no auto-increment; UUIDs avoid hot-partition issues that integer-sequence keys would create
- **Sort key**: none (single-item-per-PK model; each execution is independent)
- **Attributes**: `status`, `range_start`, `range_end`, `primes` (List), `primes_count`, `duration_ms`, `error_message`, `created_at` (Number, epoch seconds), `started_at`, `completed_at`, `ttl_at` (Number, epoch seconds for DynamoDB TTL feature)
- **GSI**: none in v1. If V2 ops need "list all running executions for stale-detection at scale", add `status_index` (PK = `status`, SK = `created_at`). For the case-study workload size, scan with FilterExpression is acceptable.
- **TTL**: status-aware via the `ttl_at` attribute set on insert/update:
  - `status = done` → TTL = created_at + 30 days (industry-conventional application audit retention)
  - `status = failed` → TTL = created_at + 90 days (forensic / RCA support)
  - `status = running` or `queued` → no TTL (don't auto-delete in-flight work)
- **Capacity mode**: on-demand (PAY_PER_REQUEST) — burst-shaped workload doesn't justify provisioned reservation
- **Stream**: `NEW_AND_OLD_IMAGES` enabled (V2 hook for archival to S3 / event-driven downstream consumers)

### Read/write semantics

- **Idempotency check** (worker before computing): `update_item` with `ConditionExpression: status = queued AND attribute_exists(execution_id)` — DynamoDB's native conditional write is the equivalent of "INSERT ON CONFLICT IGNORE". Atomic; no race conditions; same semantics as the PG worker's row-state check.
- **Status transitions** (queued → running → done | failed): conditional `update_item` with `ConditionExpression` checking the previous status. Prevents out-of-order updates.
- **Local read** (within originating region): `ConsistentRead=true` for strong-consistent reads on the local replica. Sub-millisecond.
- **Cross-region read** (operator polls a region different from the writer): eventual consistency (~1s replication lag). Acceptable for the polling pattern; client polls again if status hasn't propagated. RPO = 1s.
- **Conflict resolution** (concurrent writes from different regions to same item): last-writer-wins by writer-side timestamp. For the workload — execution_id is UUID4, so cross-region collision is statistically zero; status transitions are monotonic so even if two regions update concurrently, the result converges.

### Routing layer (Route53)

- Single hosted zone for the deployment domain (e.g., `api.enclave.example`)
- Two record sets, **weighted routing policy** 50/50 between Frankfurt ALB and Ireland ALB
- Each record set has an associated **health check** on the ALB's `/health` endpoint (HTTPS, mutual-TLS not required for health endpoint — public-route via VPN-less probe path documented in scaling_runbook)
- TTL = 60s on records (cap client-side DNS cache)
- When one region's health check fails 3 consecutive times (90s), Route53 stops returning that record; clients re-resolve on TTL expiry and land on the healthy region

### Compute layer (per region)

- Each region has its own VPC + ALB + ECS cluster + Valkey + SQS + Client VPN endpoint (mirror structure)
- ECS app + worker services run at the same `desired_count` baseline in both regions (active-active)
- Worker reads from + writes to the same region's DynamoDB Global Tables replica (local strong-consistent reads + writes)
- SQS messages are region-local (no cross-region SQS; messages stay in originating region for processing locality)
- Valkey cache is region-local (no cross-region cache replication; bootstrap re-seeds in each region independently)

### Failover semantics

- **No promotion step.** Both regions are writers always.
- **No Lambda automation.** Route53 health check + record TTL handle traffic shift.
- **No failback complexity.** When the failed region recovers, its health check returns OK, Route53 restarts returning its record, and the in-region replica catches up via Global Tables replication automatically. No reconstitution, no detach-and-rebuild, no hours-of-seed.
- **RTO breakdown**:
  - Route53 health check 3 consecutive failures × 30s = 90s
  - DNS TTL = 60s; client cached resolutions expire over 60-300s
  - In-flight requests on failed region: ALB returns 5xx; client retries hit the healthy region after DNS refresh
  - **Total RTO ≈ 60-300s** (DNS-dominated; ECS already running on healthy region, no scale-up needed)
- **RPO**: ~1s typical Global Tables cross-region replication lag. Items written to the failed region in the last second before failure may not have replicated yet; on failback they propagate via the same replication path (no operator intervention).

### Local development parity

- `docker-compose.yml` adds `amazon/dynamodb-local` service alongside existing services (mirroring ADR-0030's ElasticMQ-for-SQS pattern)
- Smoke test exercises against `http://dynamodb-local:8000`; production-shape connection via `boto3.client("dynamodb", endpoint_url=...)` toggles between local/cloud via env var
- Python unit tests use `moto[dynamodb]` in-process for speed; same pattern as `moto[sqs]` already in use
- Multi-region semantics are NOT locally emulated (`amazon/dynamodb-local` doesn't support Global Tables) — verified during the cloud-up window only, same as RDS Multi-AZ failover semantics

## Alternatives Considered

| Candidate | Why not chosen |
|---|---|
| **Aurora Global Database active-passive** (ADR-0040) | The PG-existing migration path. For greenfield, rejected on operational-complexity grounds: Lambda failover automation needed (Aurora doesn't auto cross-region failover); failback Path 1 (5-10 min, reachable primary) vs Path 2 (1-12h reconstitution, disaster origin) asymmetry; split-brain risk if Lambda misfires; DDL-in-flight failure modes; cost shape comparable but operational glue is non-trivial. **The architectural complexity Aurora requires is direct evidence for choosing DynamoDB Global Tables instead.** Forkers carrying existing PG investment should evaluate ADR-0040 vs schema-migration cost; greenfield should pick this ADR. |
| **DynamoDB single-region + cross-region snapshot** | Cheaper than Global Tables (no replication WCU). Rejected: RPO becomes "time since last snapshot", typically hours; restore from snapshot is hours; this is V3 disaster-recovery posture, not active-passive multi-region production. Use case: dev/test environments. |
| **Vanilla RDS PG with cross-region read replica + manual promote** | Lower-tier of ADR-0040 (no Aurora). Rejected: RPO measured in minutes (read-replica catch-up), promotion is manual `aws rds promote-read-replica` — operator-driven RTO 15+ min, no Lambda automation built. Useful for shoestring budgets where Aurora premium isn't justified; not appropriate for production. |
| **CockroachDB or YugabyteDB self-hosted on EKS** | Distributed SQL with strong consistency cross-region; PostgreSQL wire-protocol compatible (CockroachDB). Rejected per ADR-0018 managed-default discipline — self-hosting a stateful distributed database is the exact ops surface that managed-defaults intentionally avoids. Right answer for an org with a platform team that already runs distributed databases; over-built for aegis-enclave's scale. |
| **CockroachDB Cloud (managed)** | Same architectural shape as self-hosted but with Cockroach Labs running it. Rejected: introduces a non-AWS dependency (per ADR-0040's geographic-scope clarification on staying AWS-native for the buyer's European-business shape). Right call for cloud-agnostic deployments; not for AWS-only. |
| **DynamoDB Global Tables active-passive** (Frankfurt writes only, Ireland read-only standby) | Underutilises the multi-master capability. Rejected: secondary-region cost is identical (provisioned both regions); routing-weight 50/50 vs 100/0 is one terraform line; active-active gives natural load distribution + lower-latency reads for closer-region operators. Operationally simpler too: no "is this region the primary now?" mental overhead. |
| **Active-active with TWO DynamoDB tables (one per region) replicated via custom application code** | Avoids Global Tables vendor-lock for the replication mechanism. Rejected: re-implements multi-master replication at the application layer, including conflict resolution + clock skew handling + retry semantics. Global Tables solves this at the storage layer with last-writer-wins. The vendor-lock concern is overstated — DynamoDB's API is widely emulated (LocalStack, ScyllaDB Alternator); migrating away is feasible if needed. |
| **Aurora MySQL Multi-Master** | Aurora MySQL has Multi-Master mode (single-region only); Aurora PostgreSQL does not. Rejected: workload doesn't run on MySQL; cross-region active-active is unavailable in MySQL Multi-Master either way. |

## Consequences

- **Greenfield forker promotion path**: this ADR + a multi-region terraform composition (Ireland mirror module + Global Tables `replica` config + Route53 weighted records) is the canonical V2. Estimated implementation: ~25h schema+code refactor (PG → DynamoDB) + ~10-15h multi-region infrastructure = ~35-40h total. Documented in `docs/scaling_runbook.md` Phase B.
- **Existing-PG forker promotion path**: ADR-0040 (Aurora Global migration) remains the runbook. Trade-off: 32-42h for Aurora migration + Lambda automation, ending in active-passive with operational complexity ADR-0040 documents. A forker should choose between ADR-0040 and ADR-0042 based on schema-migration appetite, not on which ADR is "more recent".
- **Schema commitment**: UUID4 PK breaks existing integer `execution_id` references in tests + smoke + cloud-smoke. Migration path on the case-study side is rewrite, not coexistence.
- **Local parity**: `amazon/dynamodb-local` Docker image becomes the local data layer (matching ADR-0030's ElasticMQ-for-SQS pattern). `docker-compose.yml` removes `postgres`, adds `dynamodb-local`. `db/init.sql` is deleted (DynamoDB tables are terraform-managed; no schema DDL).
- **Bootstrap simplification**: ADR-0035 (bootstrap task includes schema migration) is superseded — DynamoDB tables are created by terraform, no `Base.metadata.create_all` step. The bootstrap task's role narrows to cache pre-warm only.
- **Test layer**: `moto[dynamodb]` replaces `moto[sqs]`-style mocks for the data layer. Tests rewrite is part of the schema commitment.
- **SLI emission unchanged**: `src/prime_service/metrics.py` EMF emission is data-layer-agnostic; `request_total` / `request_errors_5xx` / `request_latency_ms` / `cache_hit_count` / `cache_miss_count` / `compute_duration_ms` / `poll_to_done_ms` all remain the same.
- **Cost shape (eu-central-1 + eu-west-1)**: roughly 2× single-region per-hour cost ($1.68/h vs $0.84/h per ADR-0007 reconsidered's 3-AZ posture). Plus DynamoDB Global Tables billing: replicated WCU at 1.5× standard rate (or 1× rWCU billing on PAY_PER_REQUEST ~$1.875 per million writes). For our workload (~10k requests/day): ~$0.10-0.30/month replication cost, trivial.
- **Cost shape (active-active vs active-passive)**: identical at the infrastructure level (both regions provisioned). The only "cost" difference is whether secondary's ECS sits at desired_count=1 (passive) or desired_count=3 (active). For aegis-enclave's tiny ECS task size, the delta is ~$0.024/h.
- **Operator UX simplification**: no Lambda function to maintain; no failover runbook complexity; no "which region is primary right now?" mental overhead. Active-active means both regions are always primary for writes; Route53 weight is the only thing that determines routing.
- **`tfvars-init.sh` adds `primary_region` + `secondary_region` prompts** with defaults eu-central-1 + eu-west-1 (the EU-business-fit pair). Forkers choosing different regions (e.g., us-west-2 + us-east-1) override via env var or interactive input. Single-region case-study scope can leave `secondary_region = ""` to disable Global Tables provisioning.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene calibration — this ADR is V2 production target, not case-study scope)
- ADR-0007 (single-region multi-AZ — case-study calibration; this ADR is the corresponding V2 multi-region target for greenfield)
- ADR-0008 (reliability targets — RTO 15 min / RPO 5 min are comfortably met by DDB Global Tables RTO ~60-300s + RPO ~1s)
- ADR-0009 (RDS PostgreSQL Multi-AZ — Phase 1 commitment that this ADR architecturally supersedes for greenfield, retains for existing-PG migration path via ADR-0040)
- ADR-0018 (managed-default tool selection — DynamoDB is the AWS-native managed primitive applied to the audit-log workload)
- ADR-0019 (private-only VPC — DDB endpoint accessed via VPC endpoint, no internet egress; matches existing pattern)
- ADR-0030 (ElasticMQ local SQS parity — this ADR's `amazon/dynamodb-local` choice mirrors that pattern)
- ADR-0035 (bootstrap task includes schema migration — superseded for greenfield: no schema migration needed for DynamoDB)
- ADR-0040 (Aurora Global multi-region — superseded by this ADR for greenfield; retained as PG-existing migration path)
- ADR-0041 (observability backend — SLI emission via EMF unchanged across DB engines)
- `docs/scaling_runbook.md` (the agent-executable spec for executing this ADR — Phase B)
