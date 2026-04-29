# ADR-0007: Per-region 3-AZ posture

## Status
Accepted (2026-04-28).

## Context

Each region in the deployment runs an independent VPC + ECS + ALB + Valkey + SQS + DynamoDB Global Tables replica. The decision below applies *within a region*; the cross-region multi-region story lives in ADR-0042.

Within a single region, AZ-count is the dominant fault-domain knob. The choice is between:

| AZ count | Loss-of-one-AZ capacity | Industry posture |
|---|---|---|
| 1 (no Multi-AZ) | 0/1 — full outage | Sub-production |
| 2 (minimum Multi-AZ) | 1/2 — 50% degradation | Weakest form of Multi-AZ |
| 3 | 2/3 — 33% degradation | Production-grade default |
| 4+ | further marginal gain | Diminishing returns; few regions support 4+ |

3-AZ is the production-grade Multi-AZ posture. 2-AZ is widely understood to be the weakest form because loss of one AZ leaves the workload running on a single AZ — equivalent to operating without Multi-AZ between the failure and the recovery window.

ECS task spread also depends on AZ count. With `desired_count = 1` on the app service, exactly one AZ runs the workload at any moment — the topology is Multi-AZ in principle but single-AZ in practice. With 3 AZs and `desired_count = 3`, ECS spreads one task per AZ, so AZ loss leaves 2 tasks still serving rather than 0 or 1.

DynamoDB Global Tables replicas inside each region are inherently AZ-resilient (DynamoDB is a regional service that operates across all in-region AZs internally), so the AZ-count decision affects ECS, ALB, ElastiCache Serverless, and the VPC subnet shape — not the data layer.

## Decision

Each region provisions **3 AZs** by default (`a` / `b` / `c`), with:

- 3 private subnets (one per AZ) for ECS tasks
- 3 subnets across the same AZs for the ALB target groups
- ECS app service `desired_count = 3` (one task per AZ baseline)
- ECS worker service `min_count = 3, max_count = 9` (autoscale on SQS depth, baseline one per AZ)
- 8 Interface VPC endpoints provisioned in all 3 AZs (24 ENIs per region)
- Client VPN endpoint subnet associations across all 3 AZs

Loss of one AZ leaves 2/3 capacity (33% degradation). The ALB, ECS service spread, and VPC endpoint redundancy all preserve traffic during single-AZ failure.

## Alternatives Considered

| Candidate | Notes |
|---|---|
| 2 AZs | Minimum that qualifies as Multi-AZ; loss of one AZ leaves 50% capacity. Production environments commonly use 3+ AZs to avoid the single-AZ-degraded window. |
| 4+ AZs | Few AWS regions advertise 4+ AZs as routinely available for all services in scope (ECS Fargate, ElastiCache Serverless, etc.). Marginal fault-domain gain over 3 AZs is small relative to the per-AZ infrastructure cost (additional VPC endpoints, additional ENI-hours). |
| Single AZ | Sub-production posture; any AZ event takes the workload offline. Free architectural credit (Multi-AZ across 3 AZs in eu-central-1 / eu-west-1) makes single-AZ an inferior default. |

## Consequences

- **Cost**: 3-AZ posture adds ~$0.24/h vs single-AZ idle in eu-central-1 (interface VPC endpoints in 3 AZs + Client VPN endpoint × 3 associations + ECS baseline tasks × 3). Per-region steady-state idle ~$0.84/h documented in `docs/deployment_guide.md` § Cost shape.
- **Failure semantics**: single-AZ failure leaves 2/3 ECS task capacity in the affected region. Combined with ADR-0042's cross-region active-active routing (Route53 weighted), AZ loss in one region does not require cross-region failover — the in-region 2/3 capacity is sufficient for the load profile in `docs/design_doc.md` § 4.1 (50-100 RPS bursts ≤ 30s).
- **DynamoDB independence**: data layer AZ-resilience is provided by DynamoDB itself; this ADR's 3-AZ posture applies to the compute / network / cache plane.
- **VPC subnet plan**: each region uses a `/16` parent CIDR with three `/24` private subnets. Non-overlapping CIDR pairs across regions (e.g., `10.0.0.0/16` Frankfurt, `10.1.0.0/16` Ireland) preserve the option for VPC peering / Transit Gateway if cross-region private connectivity becomes necessary.

## Related ADRs
- ADR-0008 (reliability targets — RTO 15 min / RPO 5 min are met by the per-region 3-AZ posture combined with ADR-0042's cross-region routing)
- ADR-0011 (network topology — hub-and-spoke realised through the per-region private VPC)
- ADR-0019 (private-only VPC — same VPC realised via 3-AZ private subnets and 3-AZ VPC endpoints)
- ADR-0042 (cross-region active-active — both regions are provisioned with this 3-AZ in-region posture)
