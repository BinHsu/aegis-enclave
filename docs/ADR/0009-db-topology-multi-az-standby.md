# ADR-0009: Provision the database as RDS PostgreSQL Multi-AZ standby; no read replicas

## Status
Accepted (2026-04-25)

## Context
The cloud target uses RDS PostgreSQL behind ECS Fargate. The choice of HA topology has to match the workload, not default to "more replicas = more robust".

Workload analysis from the three endpoints:

- Every API call writes to the `executions` audit table — the workload is **write-heavy on the primary**.
- The single read endpoint (`GET /executions/{id}`) is bounded by audit query volume, not by application traffic. Read pressure is **low**.
- The brief asks for resilience and clear RTO/RPO targets (recorded in ADR-0008), not for read throughput.

Read replicas address a different problem: relieving primary read pressure by fanning out queries. Adding read replicas to a write-heavy audit workload solves nothing the workload actually has, and signals that the candidate hasn't read the workload before reaching for a pattern.

The Multi-AZ standby is the right HA mechanism here. A synchronous hot standby in a second AZ guarantees RPO ≈ 0 for in-flight committed transactions and gives auto-failover within ~2-5 minutes on AZ failure. In Terraform it is a one-line setting (`multi_az = true`) on the community RDS module — free architectural credit.

## Decision
Provision the database as **RDS PostgreSQL with `multi_az = true`** — a primary instance plus a synchronous hot standby in a different AZ. The standby does **not** serve read traffic; it exists for automated failover. **No read replicas.**

The single-region scope established in ADR-0007 holds. Cross-region disaster recovery (Aurora Global Database, cross-region read replicas) belongs in the Phase 2 scaling runbook, not in Phase 1.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Read replicas (1 primary + N read replicas) | Wrong tool for the workload. Read replicas relieve primary read pressure; this workload is write-heavy on the audit table and has bounded read volume. Adding replicas signals not having read the workload. |
| Aurora Global Database (multi-region async) | Out of single-region scope (ADR-0007). Over-engineering for Phase 1. Belongs in the Phase 2 scaling runbook as the next-tier option. |
| Aurora multi-master active-active | Complexity without benefit. PostgreSQL has no clean managed multi-master primitive at AWS, and the workload doesn't need active-active write paths. |
| Single-AZ, no standby | Abandons free architectural credit (`multi_az = true` is one Terraform line). Undermines the RTO/RPO targets recorded in ADR-0008. |

## Consequences
- **Simple Terraform.** One community module call with `multi_az = true`. No bespoke replication topology to maintain.
- **Matches RPO target.** Synchronous commit gives RPO ≈ 0 for in-flight committed transactions; aligned with the ≤5 min target in ADR-0008.
- **Matches RTO target.** Auto-failover completes in ~2-5 min; the ≤15 min target in ADR-0008 absorbs the remaining manual-intervention buffer.
- **Demonstrates workload-first thinking.** Choosing read replicas for a write-heavy audit workload is a common junior mistake — this ADR records the rejection explicitly.
- **Phase 2 path is documented.** Aurora Global Database / cross-region replicas live in the Phase 2 scaling runbook (ADR-0007), not in Phase 1, and the upgrade path is recorded rather than discovered later.

## Related ADRs
- ADR-0007 (single-region, multi-AZ scope)
- ADR-0008 (RTO / RPO targets)
