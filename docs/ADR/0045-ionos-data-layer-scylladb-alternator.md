# ADR-0045: IONOS-side data layer — ScyllaDB Alternator (self-hosted, DynamoDB-wire-compatible)

## Status
Accepted (2026-05-20)

## Context

ADR-0042 chose **DynamoDB Global Tables** as the production data store for aegis-enclave: active-active multi-master across `eu-central-1` + `eu-west-1`, on-demand capacity, Route53-weighted DNS failover, RPO ~1 s. The application uses `boto3.client("dynamodb", ...)` against this store; `src/prime_service/db.py` is a thin wrapper around the DynamoDB API.

The migration runbook (`docs/migration_runbook.md`, ADR-0012) was authored before that pivot. Its Track 1 step 1.2 targeted **IONOS DBaaS PostgreSQL** with the `terraform-aws-modules/rds/aws` → `ionoscloud_dbaas_pgsql_cluster` mapping. After ADR-0042 that step is stale at two layers:

1. **Wrong source primitive.** The source is no longer AWS RDS PostgreSQL; it is AWS DynamoDB. The mapping table row is mislabelled.
2. **Wrong target primitive.** IONOS DBaaS PostgreSQL cannot be a drop-in target for a DynamoDB workload — the application would need a concurrent SQL rewrite (schema, ORM layer, query translation), which breaks the runbook's central theme of "preserve the application, swap the infrastructure."

The pivot removed something the original runbook quietly relied on: **a managed-service parity hop on the destination cloud**. IONOS Cloud does not offer a managed DynamoDB-compatible NoSQL service. The runbook must either (a) accept that the IONOS leg has no managed parity and document a self-hosted target honestly, or (b) ignore the gap and ship a stale step. The case study has already shipped; this ADR closes (a).

### Workload constraints (recap, from ADR-0042 + ADR-0008)

- Tier 2 ops support workload — RTO 1–4 h industry baseline, RPO 5 min – 1 h baseline; aegis-enclave hits ~60–300 s on AWS.
- Single-table audit-log model — PK `execution_id` (UUID4), no sort key, no load-bearing GSI in v1.
- Burst-shaped traffic — 50–100 RPS for ≤ 30 s, idle baseline ~1 req/min.
- Single-item conditional writes (`status` state-machine transitions).
- No regulated PII; 30-day / 90-day TTL by status.
- `boto3` client; AWS-CLI `dynamodb scan` is the parity-verification primitive.

### Target candidates surveyed

| Candidate | API parity with boto3 | Self-host posture | Operational burden |
|---|---|---|---|
| ScyllaDB Alternator (Apache-2.0, OSS) | DynamoDB wire protocol — `boto3` works unchanged with `endpoint_url=` override | Self-host on IONOS compute; 3-node cluster across IONOS AZs | NoSQL operator skillset; repair scheduling; JMX monitoring; version upgrades |
| ScyllaDB Cloud / ScyllaDB Enterprise | DynamoDB Alternator API | Vendor-managed (paid SaaS, not on IONOS) | Lower — but introduces a non-IONOS dependency on the IONOS leg, defeating the EU-sovereign destination story |
| Cassandra (Apache-2.0) | Native CQL only — no DynamoDB wire protocol | Self-host; same multi-node story | Same as Scylla operationally; plus requires app rewrite from boto3 to a CQL driver — breaks "preserve the application" theme |
| LocalStack / dynamodb-local on IONOS | DynamoDB wire protocol (dev-grade) | Single-process Docker container | Not production-graded; no replication, no HA, no durability guarantees beyond a single volume |

ScyllaDB Alternator is the only candidate that **(1) preserves `boto3` unchanged** and **(2) has a production-graded self-host story** and **(3) avoids introducing a third-party SaaS dependency on the IONOS leg**.

## Decision

The IONOS-side data layer in `docs/migration_runbook.md` Track 1 step 1.2 targets **ScyllaDB self-hosted on IONOS compute, with the Alternator API enabled**.

### Cluster topology

- **3 nodes** — one per IONOS availability zone within the Frankfurt (`de/fra`) datacenter. Each node a `cpu-dedicated`-class IONOS VM: 4 vCPU / 16 GiB RAM / 100 GiB NVMe-equivalent storage.
- **Single datacenter, multi-AZ.** No second-DC replication in v1. This is the honest limit — see Consequences.
- **Replication factor 3** (NetworkTopologyStrategy across the 3 AZs); **consistency level `LOCAL_QUORUM`** for both reads and writes. Tolerates loss of one AZ.
- **Version pin**: ScyllaDB 6.x LTS (latest stable at runbook execution time; the runbook's Step 1.2 `precondition` field names the exact version, not this ADR — keeps version drift out of architectural records).
- **Alternator listener** on port 8000; native CQL listener on port 9042 left enabled for operator debugging via `cqlsh`. Application connects only to Alternator.

### API enablement and application contract

- ScyllaDB Alternator is enabled via `--alternator-port 8000 --alternator-write-isolation always` in the scylla daemon config.
- The application connects via `boto3.client("dynamodb", endpoint_url="http://<scylla-node>:8000", region_name="eu-central-1", aws_access_key_id="local", aws_secret_access_key="local")`. The credential fields are placeholders — Alternator does not validate them at the application boundary. Authentication is network-bound (private LAN + firewall rules per ADR-0011 hub-and-spoke).
- `src/prime_service/db.py` is **unchanged** between the AWS and IONOS legs. The endpoint URL is the only configuration variable that differs.

### Capacity sizing rationale (Tier 2 alignment)

- Per ADR-0008, Tier 2 RTO 1–4 h. A 3-node Alternator cluster with `LOCAL_QUORUM` tolerates one node failure with no RTO impact (sub-second client retry to a peer). Two-node failure requires manual recovery — fits within the Tier 2 envelope.
- Burst traffic ceiling (100 RPS for 30 s) is ~3000 ops total, trivially within a 3-node Scylla cluster's headroom on the specified hardware. Idle baseline is sub-percent utilisation.
- Storage: 100 GiB per node × 3 nodes ÷ 3 replication factor = ~100 GiB usable. At ~1 KiB per audit row and 90-day TTL on failures + 30-day TTL on completed runs, the workload writes < 10 GiB/month — order-of-magnitude headroom.

### TTL semantics

ScyllaDB supports per-row TTL natively. The ADR-0042 TTL policy (`done = 30 days`, `failed = 90 days`, in-flight = no TTL) is preserved at the application layer by passing `TimeToLiveSpecification` via the same `boto3.client.update_time_to_live` API the AWS side uses. Alternator implements this.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **PG-rewrite on IONOS DBaaS PostgreSQL** — provision `ionoscloud_dbaas_pgsql_cluster`, rewrite `src/prime_service/db.py` to use SQLAlchemy or `psycopg`, translate DynamoDB conditional writes to SQL `INSERT ... ON CONFLICT` semantics, translate TTL to a periodic cleanup job | Requires concurrent application rewrite in lockstep with the infrastructure swap. Breaks the runbook's central theme: "preserve the application, swap the infrastructure." The runbook's value as a portfolio artifact is the agent-executable spec for infrastructure migration — a coupled code rewrite turns the runbook into a multi-week project and dilutes that artifact. IONOS DBaaS PostgreSQL is the right target for a workload that was already SQL; it is not the right target for a NoSQL workload. |
| **PostgreSQL on IONOS DBaaS with a DynamoDB-to-relational mapping layer** — keep `boto3` calls in `db.py`; introduce a translation adapter (PynamoDB-style shim or custom abstraction) mapping DynamoDB operations to SQL behind the scenes | Same cost as the rewrite (the adapter is just rewritten code in a different module) plus an unmaintainable abstraction. Conditional-write semantics, single-item atomicity, and TTL all have to be re-implemented in SQL — and re-implemented correctly. This is a class of code that is famous for harbouring subtle bugs. Net negative on every axis. |
| **Status-banner-only — declare IONOS leg unmigratable for this data layer; document that the runbook stops at the K8s + ALB layer** | Operator instruction explicitly rejected this. The runbook's premise is end-to-end actionability against IONOS; truncating it at the data layer makes it a partial artifact. Honest is better than absent — a self-hosted target with documented operational burden beats a documented gap. |
| **ScyllaDB Cloud (managed SaaS on the vendor's infrastructure)** | Introduces a non-IONOS dependency on the IONOS leg. The IONOS-target story is EU-sovereign destination — bringing in a third-party SaaS for the data layer defeats that framing. Self-hosted on IONOS compute keeps the destination posture coherent. |
| **Cassandra (Apache-2.0) self-hosted** | Native CQL only — `boto3` does not work against Cassandra. Forces an application rewrite (boto3 → CQL driver), which is exactly what the Alternator choice avoids. Same operational burden as Scylla without the API-parity upside. |

## Consequences

### Accepted trade-offs (honest caveats)

- **Loss of multi-region active-active on the data layer at the IONOS leg.** AWS-side DynamoDB Global Tables spans `eu-central-1` + `eu-west-1` active-active with ~1 s RPO. The IONOS leg is a single 3-node cluster across IONOS AZs within one datacenter. RPO on the IONOS leg = effectively 0 within-DC (synchronous quorum writes) but the cross-DC story is gone. If a forker needs IONOS multi-DC parity, the runbook step gains a follow-up "cross-DC Scylla replication via DC2 keyspace strategy" sub-step, but that is out of scope for v1.
- **Operational burden of self-hosted NoSQL.** Repair scheduling (`nodetool repair` weekly), JMX monitoring, ScyllaDB version upgrades (rolling restart per node), node-replacement procedures, and capacity planning all move from "AWS handles it" to "operator handles it". The runbook's Step 1.2 `on_failure` block names the high-frequency failure modes; longer-tail operations (cluster expansion, datacenter migration) are not covered by the runbook and would require operator runbooks of their own.
- **No managed-service parity on the IONOS leg.** This is the architectural fact, not a regression. IONOS does not sell a DynamoDB-compatible managed service. The runbook documents this honestly rather than papering over it.
- **Eventual-consistency knob differs.** AWS DynamoDB exposes `ConsistentRead=true` on a per-call basis (sub-millisecond on local replica). Scylla Alternator uses CL=`LOCAL_QUORUM` cluster-wide; the per-call boolean is honoured but behaviour is governed by the cluster configuration, not the call. The application's current use of `ConsistentRead=true` is satisfied; nothing in `db.py` changes.

### Preserved (main upside)

- **`src/prime_service/db.py` is unchanged.** The boto3 client works against Alternator with only the `endpoint_url` differing. No application code change, no schema migration step, no test rewrite.
- **The runbook's "preserve the application, swap the infrastructure" theme holds.** Step 1.2 swaps infrastructure (DDB → Scylla Alternator) without touching `src/`.
- **Parity verification primitive is unchanged.** AWS-CLI `dynamodb scan` works against both endpoints (the AWS DDB endpoint and the IONOS Alternator endpoint) because the wire protocol is the same. The runbook's cutover step (1.7) verifies data parity by scanning both endpoints with the same command, only changing `--endpoint-url`.
- **Apache-2.0 OSS** — no licence surface, no vendor lock on the IONOS leg, no per-node enterprise fee.

### Operational consequences

- The runbook's Step 1.2 `human_gate` becomes `true` (was `false` under the DBaaS PG model). Cluster bootstrap is not idempotent in the same way managed-DBaaS provisioning is — bootstrap order matters (seed node first, then peer joins), version pinning matters, and config drift between nodes matters. Operator gates the step.
- `verify_cmd` shifts from `ionosctl dbaas postgres cluster list` to a combination of `nodetool status` over SSH and `curl http://<node>:8000` against the Alternator endpoint (the latter returns an HTTP 400 "missing X-Amz-Target header" on a bare GET, which is itself the success signal — the daemon is listening and parsing the DynamoDB wire protocol).
- Backup posture differs: AWS DDB has continuous PITR + on-demand snapshots; Scylla has `nodetool snapshot` (per-node, operator-scheduled). The runbook's Step 1.2 leaves backup scheduling as a follow-up; this ADR notes it as a known gap for forkers carrying the runbook to production.

## Related ADRs

- ADR-0008 (Tier 2 RTO calibration — single-DC 3-node Scylla cluster fits within the 1–4 h envelope)
- ADR-0011 (hub-and-spoke topology — Alternator listener is reachable only from the IONOS application LAN, not the public internet)
- ADR-0012 (migration runbook agent-executable schema — this ADR's decision is materialised in Step 1.2 of that runbook)
- ADR-0018 (managed-default tool selection — Alternator is the self-hosted exception forced by IONOS's lack of a DynamoDB-compatible managed service)
- ADR-0037 (secret minimization — Alternator authn is network-bound + firewall-gated, no DB password rotation surface, consistent with the AWS-side IAM-authn posture)
- ADR-0042 (DynamoDB Global Tables — the AWS-side decision this ADR closes the destination-cloud parity gap for)
- ADR-0044 (region-stack module — irrelevant to the IONOS leg since IONOS provisioning lives in the runbook's `action` blocks, not in terraform; noted here to mark non-applicability explicitly)
