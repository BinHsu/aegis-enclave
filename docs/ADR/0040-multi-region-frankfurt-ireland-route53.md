# ADR-0040: Multi-region production target — Frankfurt primary + Ireland standby with Route53 health-based failover

## Status
Accepted (2026-04-28) — **target architecture, not implemented in the case-study cycle.**

This ADR records the production endpoint architecture. The case-study deliverable is single-region (`eu-central-1`) per ADR-0007 (single-region multi-AZ posture) and within the build-budget cap of ADR-0034 (24h). The promotion path is `docs/scaling_runbook.md` (multi-region scaling spec, agent-executable).

## Context

### Geographic scope clarification (read this first)

The "multi-region" in this ADR's title is **EU multi-region for HA/DR within a single business region**, NOT global-customer reach. The deliverable explicitly targets a European-business deployment shape:

- **No CDN** (no CloudFront, no Akamai, no Fastly). Traffic is internal-VPN-gated per ADR-0006 and ADR-0019; the access pattern is "operator on Client VPN → internal ALB → ECS", not "global anonymous web user → CloudFront edge → ALB". CDN solves a problem this architecture doesn't have.
- **No global database** (no DynamoDB Global Tables, no Aurora cross-continent topology). The data residency stance is *EU only*; replication targets within `eu-central-1` + `eu-west-1` are EU-jurisdictional and stay EU-jurisdictional.
- **No additional region beyond Frankfurt + Ireland.** Adding `us-east-1` or any APAC region would introduce data-export friction (GDPR Standard Contractual Clauses or Adequacy Decision processing for any data crossing the EU boundary), latency that doesn't help EU customers, and operational complexity disproportionate to the customer geography being served.

This scope is deliberate. A space-cargo customer based in Bremen / Frankfurt / Brussels / Stockholm is best served by a Frankfurt-primary deployment with Ireland-standby, not by a globally-distributed edge-cached SaaS architecture. Targeting the actual business geography is the calibration; assuming "more regions = more better" would be a misread of the operational shape.

### Why multi-region (within EU) is required for production

ADR-0007 fixed the deliverable as single-region multi-AZ on the calibration that PoC scope and 24h budget did not justify the multi-region operational lift (cross-region replication, failover orchestration, Route53 health-checked DNS, dual Client VPN endpoints). That stance was correct for the case-study artifact.

Production deployment is not the case-study artifact. A production deployment of `aegis-enclave` for actual operational use (e.g., a space-cargo company processing payload manifests, telemetry, or customer data) needs the operational guarantees that single-region cannot provide:

- **RTO during a region outage**: single-region has no recovery path for a regional event (AWS region failure, regional networking incident, regional control-plane degradation). Operations stop until the region recovers.
- **RPO across region failure**: data written to RDS in `eu-central-1` is not durable against region loss. RDS Multi-AZ replicates synchronously *within* a region only.
- **Maintenance window flexibility**: maintenance work in one region can be coordinated against the other; single-region forces all maintenance into one shared window.

The pairing chosen for the production target is **`eu-central-1` (Frankfurt) primary + `eu-west-1` (Ireland) standby**. The reasoning:

- **EU sovereignty**: both regions are within the EU, so customer data does not cross GDPR transfer boundaries during failover. No cross-jurisdiction data-export contract is required to fail over.
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

- **RTO (time to traffic on secondary)**: ~3 minutes worst case. Breakdown: Route53 health check 3 consecutive failures × 30s = 90s + DNS propagation at TTL=60s up to ~60s + ECS UpdateService scaling app from 1 → 3 takes ~60s (warm-pool tasks). Within ADR-0008 RTO target of 15 minutes.
- **RPO (data loss bound)**: Aurora Global Database replication lag is typically < 1 second under normal load. ADR-0008 RPO target ≤ 5 min for durable writes is comfortably met. RDS read-replica fallback gives RPO of "the time since last replica catch-up", which has been observed at sub-minute under steady load.
- **Failback**: manual operator decision after the primary region is healthy and the data delta has been resolved (Aurora Global supports backwards switchover; RDS read-replica path requires DMS or dump-restore — V2 work).

## Alternatives Considered

| Candidate | Why not chosen |
|---|---|
| **Active-active Frankfurt + Ireland** | Doubles steady-state cost. Requires conflict resolution at the application layer for any concurrent write path. The prime-computation workload doesn't need it (writes are append-only audit rows + compute results that are deterministic given inputs); the operational complexity dominates the marginal value. Rejected. |
| **Frankfurt + Stockholm (eu-north-1)** | Sweden + Germany also EU sovereignty. Stockholm is a newer region with fewer edge points (slightly higher latency from non-Nordic operators). Frankfurt-Ireland is the more conservative choice and fits the German space-cargo deployment shape better. Rejected for this target; Stockholm is a valid forker substitution if the operator's user base is Nordic-heavy. |
| **Frankfurt + US (us-east-1)** | Crosses the EU-US data boundary; requires an EU-US data transfer agreement (Standard Contractual Clauses or Adequacy Decision). Operationally heavier. Rejected for the GDPR-clean target. |
| **CloudFront + multi-region origin** | Adds a CDN edge layer in front of the ALB(s). Useful for global anonymous web traffic. **Not useful here**: the access pattern is operator-on-Client-VPN reaching an internal ALB, not public web requests. CDN edge caching does not fit a VPN-gated single-tenant deployment. Rejected by problem-fit, not by cost. |
| **Aurora Global Database with secondary in `us-east-1`** | The data residency stance is EU-only (per the geographic scope clarification above). Crossing the Atlantic for the standby breaks GDPR-clean failover semantics. Rejected by data-residency policy. |
| **Vanilla RDS cross-region read replica (no Aurora)** | Avoids the migration from vanilla RDS PostgreSQL to Aurora. Trade-offs: (a) RPO worse (minutes vs ~1 second); (b) failover is manual (promote replica, swap connection string), not automatic. Acceptable for an interim — recorded as an alternative path for forkers who don't want the Aurora migration cost. |
| **DynamoDB Global Tables instead of Aurora Global** | Truly multi-master, no migration overhead. Rejected: the schema is relational (executions table with foreign keys, range queries by created_at, paginated reads) — DynamoDB's single-table model would force a redesign that exceeds the target's scope. |
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
- ADR-0008 (reliability targets — RTO 15 min / RPO 5 min provide the budget against which this target's 3-min RTO and < 1s RPO are measured)
- ADR-0009 (DB topology Multi-AZ standby — the within-region replication that this ADR extends across regions via Aurora Global)
- ADR-0024 (VPN cert provisioning — operator-laptop CA shared across regions)
- ADR-0034 (build budget 22 → 24h — the budget that explicitly excluded multi-region from the case-study cycle)
- ADR-0037 (secrets rotation deferred — same V2-target shape; production adoption picks both up)
- `docs/scaling_runbook.md` (the agent-executable spec for executing this ADR)
- `docs/migration_runbook.md` (cross-cloud variant; references this ADR's region-pair pattern as the within-AWS analogue)
