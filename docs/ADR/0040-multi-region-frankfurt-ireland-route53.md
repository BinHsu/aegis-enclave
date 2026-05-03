# ADR-0040: Multi-region via Aurora Global Database — Frankfurt primary + Ireland secondary (PG-existing migration path)

## Status
Accepted (2026-04-28) — **alternative path for forkers carrying existing PostgreSQL/RDS investment.**

The greenfield production target uses **ADR-0042 (DynamoDB Global Tables active-active)** — no promotion step, no Lambda failover orchestration, no failback reconstitution complexity, RTO ~60–300 s (DNS propagation only). This ADR is retained as the runbook for forkers who have already invested in PG schemas + ORM tooling + tests bound to PG semantics, where redesigning the data layer costs more than living with Aurora's failover semantics.

The PG/Aurora-Global path's operational complexity (Lambda automation, failback semantics, Path 2 reconstitution 1–12 h) is documented below in full. The promotion runbook is `docs/scaling_runbook.md` (agent-executable spec).

## Context

### Geographic scope clarification (read this first)

The "multi-region" in this ADR's title is **EU multi-region for HA/DR within a single business region**, NOT global-customer reach. The deliverable explicitly targets a European-business deployment shape:

- **No CDN** (no CloudFront, no Akamai, no Fastly). Traffic is internal-VPN-gated per ADR-0006 and ADR-0019; the access pattern is "operator on Client VPN → internal ALB → ECS", not "global anonymous web user → CloudFront edge → ALB". CDN solves a problem this architecture doesn't have.
- **EU-only data residency**: replication targets within `eu-central-1` + `eu-west-1` are EU-jurisdictional. Multi-region setup (Aurora Global on this path; DynamoDB Global Tables on the ADR-0042 path) stays EU-jurisdictional.
- **No additional region beyond Frankfurt + Ireland.** Adding `us-east-1` or any APAC region would introduce data-export friction (GDPR Standard Contractual Clauses or Adequacy Decision processing for any data crossing the EU boundary), latency that doesn't help EU customers, and operational complexity disproportionate to the customer geography being served.

This scope is deliberate. A space-cargo customer based in Bremen / Frankfurt / Brussels / Stockholm is best served by a Frankfurt-primary deployment with Ireland-standby, not by a globally-distributed edge-cached SaaS architecture. Targeting the actual business geography is the calibration; assuming "more regions = more better" would be a misread of the operational shape.

### Why multi-region (within EU) is required for production

ADR-0007 fixed the deliverable as single-region multi-AZ on the calibration that PoC scope and 24h budget did not justify the multi-region operational lift (cross-region replication, failover orchestration, Route53 health-checked DNS, dual Client VPN endpoints). That stance was correct for the case-study artifact.

Production deployment is not the case-study artifact. A production deployment of `aegis-enclave` for actual operational use (e.g., a space-cargo company processing payload manifests, telemetry, or customer data) needs the operational guarantees that single-region cannot provide:

- **RTO during a region outage**: single-region has no recovery path for a regional event (AWS region failure, regional networking incident, regional control-plane degradation). Operations stop until the region recovers.
- **RPO across region failure**: data written to RDS in `eu-central-1` is not durable against region loss. RDS Multi-AZ replicates synchronously *within* a region only.
- **Maintenance window flexibility**: maintenance work in one region can be coordinated against the other; single-region forces all maintenance into one shared window.

The pairing chosen for the production target is **`eu-central-1` (Frankfurt) primary + `eu-west-1` (Ireland) standby**. The reasoning:

- **EU sovereignty (GDPR-clean residency layer)**: both regions are within the EU, so customer data does not cross GDPR transfer boundaries during failover. No cross-jurisdiction data-export contract is required to fail over. **Note**: this is *GDPR-clean data residency* — distinct from *partition-level sovereignty* offered by AWS European Sovereign Cloud (separate AWS partition operated by EU legal entity, addressing US CLOUD Act exposure). See Alternatives table for the partition-level option. The choice here is the residency layer; AWS ESC is the partition layer.
- **Geographic + fault-domain separation**: ~1500 km apart, different power grids, different cable landings, different operational teams. A regional event in Frankfurt is statistically very unlikely to coincide with one in Ireland.
- **AZ count**: both regions have 3 Availability Zones available, so the within-region multi-AZ posture (per the 3-AZ refinement to ADR-0007) carries forward consistently into the standby region.
- **Latency**: ~25-30 ms RTT between Frankfurt and Ireland. Acceptable for async replication and for client failover (no human-perceptible delay shift after Route53 flips).
- **Cost shape**: Ireland is comparable to Frankfurt in list pricing (~5-10% variance per service); the standby-region cost approximation is "the primary's cost, again".
- **AWS maturity**: `eu-west-1` is one of AWS's longest-running regions (launched 2007), full feature parity with `eu-central-1`, mature for ops handoff.

The active-passive pairing (primary handles all traffic; standby is warm but idle) was chosen over active-active because:

- Active-active requires application-level conflict resolution for any non-idempotent write path, which the prime-computation workload doesn't actually need (compute results are deterministic given the input range).
- Active-active doubles steady-state cost without doubling steady-state value at this scale.
- Active-passive is the simpler operational model: clear primary, clear standby, clear failover trigger.

## Decision

The production endpoint architecture is multi-region active-passive with Route53 health-based failover. Specifically:

### Topology

```
                    Route53 hosted zone
                    api.enclave.example
                          │
        ┌─────────────────┴─────────────────┐
        │                                   │
   PRIMARY (failover_policy = "PRIMARY")   SECONDARY (failover_policy = "SECONDARY")
   health_check = HTTPS GET /health       health_check = HTTPS GET /health
        │                                   │
        ▼                                   ▼
   eu-central-1 (Frankfurt)             eu-west-1 (Ireland)
   ┌──────────────────────────┐         ┌──────────────────────────┐
   │ ALB (internal)           │         │ ALB (internal)           │
   │ ECS Fargate × 3 AZs      │         │ ECS Fargate × 3 AZs      │
   │ Aurora PostgreSQL ◄─async│ ───────►│ Aurora replica           │
   │ ElastiCache Valkey       │         │ ElastiCache Valkey       │
   │ SQS (primary queue)      │         │ SQS (independent queue)  │
   │ Client VPN endpoint      │         │ Client VPN endpoint      │
   └──────────────────────────┘         └──────────────────────────┘
        │                                   │
   ECR replication ────────────────────────►│
   (source: eu-central-1)                   (destination: eu-west-1)

   Secrets Manager replicate_regions = ["eu-west-1"]
```

### Component-by-component decisions

| Component | Primary | Secondary | Failover mechanism |
|---|---|---|---|
| **DNS** | Route53 record `api.enclave.example` failover policy `PRIMARY` → Frankfurt ALB DNS | Same record, failover policy `SECONDARY` → Ireland ALB DNS | Route53 health check (HTTPS GET /health every 30s, 3 consecutive failures → ALARM → flip primary record to secondary; TTL 60s on the records caps client-side DNS cache delay) |
| **ALB** | Internal ALB in Frankfurt VPC | Internal ALB in Ireland VPC | Independent — each region's ALB serves its own ECS tasks |
| **ECS Fargate** | App + worker services, 3 tasks each across 3 AZs | App service warm at desired_count = 1 (cost-optimised standby); worker scales from 1 only after failover | App service rolls to 3 on failover via CloudWatch alarm → ECS UpdateService; worker autoscale will catch up automatically as queue depth rises |
| **Database** | Aurora PostgreSQL 16 cluster, writer in `eu-central-1` | Aurora replica in `eu-west-1` (read-only until failover) | **Migration required**: case-study uses vanilla RDS PostgreSQL Multi-AZ. Production target requires migrating to Aurora Global Database for the ~1 second async replication + automatic failover via cluster endpoint switching. Alternative: vanilla RDS cross-region read replica with manual promotion (RPO minutes; trade-off documented). |
| **Cache** | ElastiCache Serverless Valkey in Frankfurt | Independent ElastiCache Serverless Valkey in Ireland | Cache state is rebuilt from RDS on failover; bootstrap task reseeds the prewarm range. Cache is intentionally not replicated — the eventual-consistency cost outweighs the rebuild cost. |
| **Queue** | SQS in Frankfurt | Independent SQS in Ireland | Messages in flight at failover are lost or stranded in Frankfurt's queue. The async architecture (ADR-0029) makes this acceptable: client polls execution_id, sees `failed` after RDS replicates the `running` row, retries with new execution_id against secondary. |
| **Image registry** | ECR in Frankfurt (push target) | ECR in Ireland with `replication_configuration` source = Frankfurt | ECR replication is automatic; new images appear in Ireland within ~1 minute of push. |
| **Secrets** | Secrets Manager primary in Frankfurt with `replica = { eu-west-1 = {} }` | Replica in Ireland | Native Secrets Manager replication; replica writes back to primary if primary is reachable, otherwise fails closed. |
| **Client VPN** | Endpoint in Frankfurt VPC | Independent endpoint in Ireland VPC | Operators have two `.ovpn` configs (`<operator>-frankfurt.ovpn`, `<operator>-ireland.ovpn`); during normal ops connect to Frankfurt; during DR connect to Ireland. mTLS PKI is shared (same CA signs both endpoints' server certs and the same operator certs). |
| **VPC peering / TGW** | No cross-region peering required for the active-passive model. Cross-region replication uses public-internet-via-AWS-backbone (Aurora Global, Secrets Manager replica, ECR replication all use the AWS backbone, not customer VPC). | Same | Failover does not require cross-region network connectivity from clients — clients DNS-resolve to whichever region is primary at the time. |

### Failover semantics (RTO / RPO targets)

- **RTO (time to traffic on secondary, with Lambda automation)**: **~5–8 minutes worst case**. Breakdown:
  - Route53 health check 3 consecutive failures × 30s = **90s**
  - Composite alarm → SNS → Lambda invocation (cold start + decision logic): **30s**
  - Lambda calls `failover-global-cluster` (disaster path) or `switchover-global-cluster` (planned path); Aurora promotes secondary writer + storage write-ownership transfer: **60–180s** (Aurora API returns in ~30s; actual promotion settle ~60–120s additional)
  - Route53 record update API call: **1–2s API + DNS TTL propagation 60–300s** (TTL=60s, but resolvers may cache)
  - ECS UpdateService secondary `desired_count` 1 → 3 + tasks healthy: **60–120s**
  - Total: 5–8 min realistic, within ADR-0008 RTO target of 15 minutes
- **RTO (operator-driven, no Lambda automation)**: ~15+ min realistic. Operator notification time + login + CLI sequence is unbounded; this exceeds ADR-0008's RTO budget if the operator is unavailable. Lambda automation is therefore the production-recommended posture; operator-driven is documented as the V2 fallback when an organisation has not built the automation yet.
- **RPO (data loss bound)**: Aurora Global Database replication lag is typically < 1 second under normal load. ADR-0008 RPO target ≤ 5 min for durable writes is comfortably met. RDS read-replica fallback gives RPO of "the time since last replica catch-up", which has been observed at sub-minute under steady load. **`switchover-global-cluster` path achieves RPO=0** (it drains in-flight writes on the original primary before transferring write ownership) but requires the original primary to be reachable; it is the planned-failover path, not the disaster path.

### Lambda automation pattern (the operational glue Aurora Global doesn't provide turnkey)

Aurora Global Database does **not** include native automatic cross-region write failover. The replication is automatic (~1s lag); the secondary serves reads automatically; **but write-ownership transfer is operator-initiated** (split-brain prevention by deliberate design). The customer-built glue is a Lambda function triggered by composite CloudWatch alarms:

```
Trigger sources (any of):
  - Route53 health check on primary ALB → CloudWatch composite alarm
  - CloudWatch alarm: primary RDS connections = 0 / region-level health
  - AWS Health Dashboard region-down event (EventBridge)
  - Manual API Gateway button (ops dashboard / Slack-bot)
                  ↓ SNS
                  ↓
        Failover Lambda (concurrency=1, timeout=5min, DLQ)
                  ↓
        (1) describe-global-clusters → check primary state
        (2) Decision:
              if primary reachable + healthy → switchover-global-cluster (RPO=0)
              else                          → failover-global-cluster (disaster path)
        (3) Wait for status='available' on new primary cluster
        (4) Update Route53 failover record → secondary ALB
        (5) ECS UpdateService secondary: desired_count 1 → 3
```

IAM scope for the Lambda execution role:
- `rds:FailoverGlobalCluster`, `rds:SwitchoverGlobalCluster`, `rds:DescribeGlobalClusters`
- `route53:ChangeResourceRecordSets` (scoped to the hosted zone)
- `ecs:UpdateService` (scoped to the secondary region's app service)
- `cloudwatch:DescribeAlarms` (for read-back state verification)

The two Aurora Global APIs the Lambda chooses between have distinct semantics:

| API | When used | RPO | Original primary disposition |
|---|---|---|---|
| `switchover-global-cluster` (added 2023, "Managed Planned Failover") | Original primary is **reachable**; controlled drain | **0** (waits for in-flight commits) | Becomes secondary; both clusters remain in same global cluster |
| `failover-global-cluster` (disaster path) | Original primary **unreachable** | < 1s (replication lag) | **Detached** — becomes standalone cluster outside the global cluster |

The disposition of the original primary is the load-bearing distinction for failback (see Failback semantics below).

### Failback semantics

Failover and failback are **not symmetric**. The cost of failback depends on which API the failover used:

| Path | When | Failback time | Reconstitution work |
|---|---|---|---|
| **Path 1** (origin = `switchover`) | Planned drain; primary was reachable | **5–10 min** | Both clusters still in same global cluster; replication direction has reversed (Ireland → Frankfurt). Verify lag < 1s, then call `switchover-global-cluster` again with Frankfurt as target. RPO=0 on failback. Lambda can fully automate. |
| **Path 2** (origin = `failover`) | Disaster; primary was unreachable | **1–12 hours** | Frankfurt's original cluster is **detached + stale + must be deleted**. Then: (a) `create-global-cluster --source-db-cluster-identifier <ireland>` to wrap Ireland's now-standalone cluster as a new global cluster, (b) `create-db-cluster --global-cluster-identifier <new-global> --source-region eu-west-1` to add Frankfurt back as new secondary, (c) **wait for initial storage seed** (1-2h for 10 GB cluster, 8-12h for 100 GB cluster), (d) wait for replication catch-up of accumulated writes (depends on outage duration), (e) finally `switchover-global-cluster` back to Frankfurt. Most of this is operator-driven; only the final switchover is Lambda-automatable. |

**Cost during Path 2 reconstitution**: double-cluster storage (Ireland primary + new Frankfurt secondary) + cross-region transfer ~$0.02/GB for the seed + ongoing replication. For a 10 GB cluster: ~$0.20 seed + $0.50/day double storage. The cost is bounded (hours-to-days) but real.

**Sharp edges shared across both paths**:
- **Split-brain risk**: Lambda must NOT fire on transient network blips. Mitigation: composite alarm with multi-condition AND (Route53 + CloudWatch metric + EventBridge), plus 5-min cooldown after each invocation.
- **DDL in-flight at failover**: an `ALTER TABLE` in-flight when failover triggers can lead to schema divergence. Production hardening: schema migrations should be backwards-compatible, and migration windows should pause failover automation.
- **Application-level read-only handling on secondary**: Aurora secondary clusters are read-only until promotion. Secondary-region app/worker must either run in a read-only health-check-only mode, or have ECS `desired_count = 0` until failover triggers (then Lambda scales up).
- **Failback is at minimum 30 min** even on Path 1 (need to verify replication caught up + plan a switchover window). Path 2 is hours-to-days. Production should not assume "we can failback whenever" — it is a planned operation.

## Alternatives Considered

| Candidate | Why not chosen |
|---|---|
| **Active-active Frankfurt + Ireland** | Doubles steady-state cost. Requires conflict resolution at the application layer for any concurrent write path. The prime-computation workload doesn't need it (writes are append-only audit rows + compute results that are deterministic given inputs); the operational complexity dominates the marginal value. Rejected. |
| **Frankfurt + Stockholm (eu-north-1)** | Sweden + Germany also EU sovereignty. Stockholm is a newer region with fewer edge points (slightly higher latency from non-Nordic operators). Frankfurt-Ireland is the more conservative choice and fits the German space-cargo deployment shape better. Rejected for this target; Stockholm is a valid forker substitution if the operator's user base is Nordic-heavy. |
| **AWS European Sovereign Cloud (Brandenburg partition)** | Distinct AWS partition (separate from commercial AWS), operated by AWS EU legal entity with EU-only personnel — addresses US CLOUD Act exposure that regular `eu-central-1` inherits (operated by AWS US legal entity). Architecturally meaningful for German space-cargo deployment shapes: **GDPR-clean residency in `eu-central-1` ≠ partition-level sovereignty in AWS ESC** — the two are different layers of the sovereignty stack. **Why not used here**: this deliverable does not have AWS ESC partition access (separate sign-up flow; not a region within standard commercial AWS accounts). Frankfurt + Ireland was chosen as the deployment target with **explicit awareness of this layer distinction** — the choice is practical (account access constraint), not a claim that `eu-central-1` delivers ESC-equivalent sovereignty. **Forker upgrade path**: workloads with US CLOUD Act exposure concerns, dual-use / defense-adjacent sensitivity, or regulated EU public-sector customer base should evaluate AWS ESC. Same SG/VPC/PrivateLink architectural shape, different partition. Forker verifies DDB Global Tables / ElastiCache Serverless / Client VPN catalog availability at deployment time (ESC service catalog launching incrementally through 2025–2026). |
| **Frankfurt + US (us-east-1)** | Crosses the EU-US data boundary; requires an EU-US data transfer agreement (Standard Contractual Clauses or Adequacy Decision). Operationally heavier. Rejected for the GDPR-clean target. |
| **CloudFront + multi-region origin** | Adds a CDN edge layer in front of the ALB(s). Useful for global anonymous web traffic. **Not useful here**: the access pattern is operator-on-Client-VPN reaching an internal ALB, not public web requests. CDN edge caching does not fit a VPN-gated single-tenant deployment. Rejected by problem-fit, not by cost. |
| **Aurora Global Database with secondary in `us-east-1`** | The data residency stance is EU-only (per the geographic scope clarification above). Crossing the Atlantic for the standby breaks GDPR-clean failover semantics. Rejected by data-residency policy. |
| **Vanilla RDS cross-region read replica (no Aurora)** | Avoids the migration from vanilla RDS PostgreSQL to Aurora. Trade-offs: (a) RPO worse (minutes vs ~1 second); (b) failover is manual (promote replica, swap connection string), not automatic. Acceptable for an interim — recorded as an alternative path for forkers who don't want the Aurora migration cost. |
| **DynamoDB Global Tables instead of Aurora Global** | **For greenfield this is the right Day 1 choice — see ADR-0042 for the full retrospective.** DynamoDB Global Tables is native multi-master multi-region active-active: zero failover orchestration (both regions are writers; conflict resolution is last-writer-wins), zero failback reconstitution (no detach-and-rebuild), RTO = DNS propagation only (~60-300s vs Aurora Global's 5-8 min with Lambda), no Aurora migration cost. The architectural mismatch documented earlier (relational schema with foreign keys) was the assumed-then-corrected constraint: the case-study brief is engine-agnostic; PG was Phase 1 commitment, not a brief mandate. **The case-study deliverable retains PG/Aurora-Global path because the schema migration is its own ~25h work + 50+ test rewrites that were not budgeted at decision time.** A forker starting greenfield should pick DynamoDB Global Tables and skip this ADR's Aurora-specific complexity entirely. The Aurora path documented here is a "migration-from-existing-investment" runbook, not a "right way to design multi-region from scratch" recommendation. |
| **AWS RAM-shared Transit Gateway for cross-region private replication** | Would route Aurora replication traffic through customer VPCs over a customer-owned TGW. Rejected: doubles operational complexity for no security benefit (Aurora replication traffic is already TLS over the AWS backbone). |
| **Two independent regions with manual promotion at failover (no Route53)** | Keeps the regions truly independent; failover is operator-driven via DNS cutover at registrar level. Rejected: RTO blows out to "however long the operator takes to log in", which is unbounded and worse than ADR-0008's 15-minute target. |

## Consequences

- **Case-study deliverable does not implement this.** The single-region composition in `terraform/main.tf` stays as-is. ADR-0040 is the documented production target.
- **Forker promotion path**: a forker promoting `aegis-enclave` to production runs `docs/scaling_runbook.md` (multi-region scaling spec) which references this ADR. The runbook expands each row of the table above into precondition / action / verify / on_failure / human_gate steps.
- **Cost shape doubles roughly.** Steady-state idle for the multi-region production target is ~2× the single-region per-hour rate documented in `README.md` § Hourly cost (so ~$1.68/h vs ~$0.84/h in the single-region 3-AZ posture, eu-central-1 list price). Plus Route53 health check $0.50/check/month + cross-region data transfer ~$0.02/GB for replication and any cross-region API traffic. Forker should run AWS Pricing Calculator before committing.
- **Aurora migration is a prerequisite if the RPO target is < 1 minute.** This is a non-trivial database migration (vanilla RDS PostgreSQL → Aurora PostgreSQL) requiring a migration window, schema compatibility verification, and connection-string changes in app + worker. Forkers can stage this independently of the multi-region rollout.
- **mTLS PKI is shared across regions.** The CA stays operator-laptop-side per ADR-0024; both regions' Client VPN endpoints import the same client CA, so the same operator certs work in both regions. No per-region cert provisioning.
- **Failover is automatic for DNS + ECS + Aurora; manual for failback.** Forward failover Frankfurt → Ireland is observable by Route53 health check + CloudWatch alarms. Failback Ireland → Frankfurt requires explicit operator decision because the data delta accumulated during the outage needs reconciliation.
- **CloudWatch alarms are duplicated across regions.** Each region has its own metric stream, its own alarm states, its own SNS topic for ops notification. The forker's ops dashboard aggregates both regions.

## Related ADRs
- ADR-0007 (single-region multi-AZ — the case-study scope decision this ADR's target supersedes for production deployments only; ADR-0007 stays as the case-study calibration)
- ADR-0008 (reliability targets — RTO 15 min / RPO 5 min provide the budget against which this target's 5-8 min Lambda-driven RTO and < 1s RPO are measured)
- ADR-0007 (per-region 3-AZ posture — the in-region resilience this ADR extends across regions)
- ADR-0024 (VPN cert provisioning — operator-laptop CA shared across regions)
- ADR-0034 (delivery methodology — the PoV staging that scopes which architectural increments ship in case-study vs forker promotion)
- ADR-0037 (secrets rotation deferred — same V2-target shape; production adoption picks both up)
- ADR-0042 (DynamoDB Global Tables greenfield retrospective — the architectural alternative this ADR considered and rejected by existing-investment constraint, not by technical fit)
- `docs/scaling_runbook.md` (the agent-executable spec for executing this ADR)
- `docs/migration_runbook.md` (cross-cloud variant; references this ADR's region-pair pattern as the within-AWS analogue)
