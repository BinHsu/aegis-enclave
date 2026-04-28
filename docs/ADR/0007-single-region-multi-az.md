# ADR-0007: Single-region eu-central-1 multi-AZ; multi-region in Phase 2

## Status
Accepted (2026-04-25)

## Context
The candidate's mental model derives from two inputs: the brief's "small application" framing, and the buyer's actual production posture (a single-mission cargo program with EU customers and EU-region ground stations). Neither input justifies multi-region in Phase 1, but skipping multi-AZ would abandon free architectural credit.

Honest implementation cost for full multi-region active-active in Phase 1, estimated by a senior practitioner who has built this shape before:

| Component | Time |
|---|---|
| Aurora Global Database (replacing single-region RDS PostgreSQL) | 2–3h |
| Cross-region VPC peering or Transit Gateway | 1.5–2h |
| Per-region ECS / ALB / Client VPN endpoints | 1.5–2h |
| Route 53 health checks + failover routing | 1h |
| Cross-region IAM, KMS, Secrets Manager replication | 1–1.5h |
| Failover drill + documentation | 1–2h |
| **Total** | **10–14h** |

That consumes the bulk of the 22h budget (revised per ADR-0028, originally 15h per ADR-0002). Cognitive complexity scales 2.5–3× (split-brain, replication lag, DNS propagation, cross-region orchestration). Cost scales 2–2.5× monthly (Aurora Global premium, cross-region transfer, duplicated managed services).

Multi-AZ inside a single region is a different shape entirely. `multi_az = true` on RDS, multi-subnet ASG on ECS — one-line Terraform toggles, no architectural complexity. Free architectural credit; declining it would read as careless and require its own ADR explanation.

The brief asked for "small application." Answering with multi-region misreads the brief. Answering with single-AZ misses free reliability. Multi-AZ in a single region is the calibrated answer.

## Decision
Deploy to a single AWS region (`eu-central-1`, Frankfurt) with multi-AZ subnet distribution and RDS Multi-AZ standby. Multi-region scaling lives in Phase 2 as an agent-executable runbook (`docs/scaling_runbook.md`), not in Phase 1 Terraform.

The design doc's Reliability section names the triggers that would move multi-region from Phase 2 plan to Phase 1 implementation:

1. Multi-capsule cargo flow with simultaneous orbital passes (multi-mission concurrency)
2. Globally distributed ground-station network requiring local-region terminations
3. Regulatory requirement for explicit geographic redundancy

None of these triggers are met at case-study scope. The reviewer reads "I have a plan" rather than "I forgot about scaling."

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Multi-region active-active in Phase 1 | 10–14h budget cost (estimate above); no business trigger met; misreads the brief's "small application" framing. |
| Multi-region warm-standby in Phase 1 | Similar time cost as active-active for marginal failover-mode difference. Same trigger argument. |
| Single-AZ (no Multi-AZ standby) | Abandons free architectural credit; reads as careless; would need an ADR explanation of its own to justify. |
| Multi-region skeleton inside Phase 1 (stub Terraform without Aurora Global) | The runbook approach (Phase 2) is more honest because it captures intent without faking implementation. A stub would mislead reviewers about what's actually deployable. |

## Consequences
- Phase 1 deliverable stays within the 22h budget (per ADR-0028) and matches the brief's "small application" framing.
- Phase 2 includes `docs/scaling_runbook.md` as agent-executable spec for moving to multi-region. It uses the same format as the cross-cloud migration runbook (see ADR-0005, ADR-0012) — proving the runbook shape generalises across axes of extension.
- The design doc's Reliability section names the (1)/(2)/(3) triggers explicitly. A reviewer scanning for "did the candidate think about scale?" finds the answer in two paragraphs, not in absent code.
- RTO 15min / RPO 5min targets are achievable with multi-AZ alone (see ADR-0008). No reliability claim is left unsupported by the chosen topology.
- If the buyer's actual production posture changes (a second mission, a US-region ground station), the scaling runbook becomes the entry point — the work is scoped, not surprise.

## Related ADRs
- ADR-0008 (reliability targets — the SLO/RTO/RPO numbers this topology supports)
- ADR-0009 (DB topology — Multi-AZ standby specifics)
- ADR-0012 (runbook format — same spec shape as the scaling runbook)
- ADR-0019 (private-only VPC — single-region multi-AZ is realised through the same VPC with private subnets only)
- ADR-0040 (production target = Frankfurt + Ireland multi-region with Route53 failover; this ADR is the case-study scope cut, ADR-0040 is the production endpoint)

---

### Reconsidered (2026-04-28): 2 AZs → 3 AZs

The original Decision said "multi-AZ subnet distribution" without specifying how many AZs. The implementation defaulted to 2 (`["${var.region}a", "${var.region}b"]`), which is the minimum that qualifies as multi-AZ but is the weakest form of it.

**Refined**: the deliverable now provisions **3 AZs** by default (`a` / `b` / `c`), with 3 private subnets + 3 database subnets and ECS Fargate task spread across all 3.

Why the refinement was needed:

- **Fault-domain coverage**: with 2 AZs, loss of one AZ leaves 1/2 capacity (50% degradation). With 3 AZs, loss of one AZ leaves 2/3 capacity (33% degradation). Production-grade multi-AZ is widely understood to mean ≥ 3 AZs precisely for this reason.
- **ECS task spread**: the original `desired_count = 1` for the app service couldn't actually exercise multi-AZ — a single task lives in exactly one AZ at any given moment. Bumping app `desired_count = 3` and worker `min_count = 3` (was 1) lets ECS spread one task per AZ, so AZ loss leaves 2 tasks still serving rather than 0 or 1.
- **RDS subnet group flexibility**: RDS Multi-AZ uses primary + standby (only 2 AZs at any moment), but the DB subnet group having 3 subnets means RDS has freedom to choose which 2 AZs to use during AZ-level maintenance windows. Without the 3rd subnet, an AZ-impacting maintenance event would have nowhere for RDS to fail over to within the same DB subnet group.
- **Carrying forward to ADR-0040**: the production target (Frankfurt + Ireland multi-region per ADR-0040) explicitly relies on within-region 3-AZ posture in both regions. Hardening 3-AZ in the case-study deliverable means the multi-region target is a region-pair operation, not a region-pair-AND-AZ-count refactor.

**Cost impact** (eu-central-1 list price):
- 8 Interface VPC endpoints × 1 extra AZ = +$0.088/h
- Client VPN endpoint association × 1 extra AZ = +$0.10/h
- 2 ECS service × 2 extra tasks each (1 → 3 baseline) × $0.012/h = +$0.048/h
- Steady-state idle: ~$0.60/h → ~$0.84/h (+40%)

The cost increase was deliberately accepted because it converts "multi-AZ in name" into "multi-AZ in fact". Per-hour cost tables in `README.md` and `docs/deployment_guide.md` updated to reflect the new rate. The case-study Phase 2.5 cost ceiling is bumped from "< $2 in 3h" to "< $3 in 3h" accordingly.

The fundamental Decision (single-region, multi-AZ in `eu-central-1`) is unchanged. This is a refinement of *how multi-AZ is implemented*, not a reversal.
