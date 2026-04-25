# ADR-0018: Tool selection principle — managed-default, self-host when scale or sovereignty demands

## Status
Accepted (2026-04-25)

## Context
Two prior ADRs in this repo make domain-specific tool-selection decisions, and both follow the same underlying logic without ever stating the logic out loud:

- ADR-0015 chose ECS Fargate over EKS for compute orchestration.
- ADR-0006 chose AWS Client VPN endpoint over self-hosted WireGuard for the cloud-side VPN gateway.

The principle behind both is: **default to the managed primitive when one exists; self-host the equivalent only when scale, sovereignty, cost, or capability gaps make the managed offering wrong.** Managed primitives (ECS Fargate, AWS Client VPN endpoint, RDS managed master password, ECR) absorb operational overhead at the provider boundary. Self-hosted equivalents pay that overhead in engineer hours instead.

Kelsey Hightower captured the same logic for Kubernetes:

> "Kubernetes is a platform for building platforms. It's a better place to start; not the endgame."

> "Most of the people who are using Kubernetes don't need it."

Kubernetes is powerful and pays operational cost for capabilities that most workloads do not use. The same is true of self-hosted WireGuard at small scale, self-hosted Vault when Secrets Manager is available, and self-hosted Postgres on EC2 when RDS exists.

The case-study deliverable sits at PoC scope (ADR-0003); none of the upgrade triggers — multi-cloud reach, EU sovereignty hard-requirement, scale ceilings, capability gaps — are met. The deliverable therefore picks managed primitives across every infrastructure layer. Phase 2 runbooks (ADR-0012) document the upgrade path for each layer using the same agent-executable spec format, so the *capability* to migrate is demonstrable without the deliverable paying *capability cost* upfront.

This ADR surfaces the principle once explicitly so future tool decisions inherit it cleanly.

## Decision
State the principle and tabulate it across both already-decided domains and adjacent layers, so the parallel is visible at a glance:

| Domain | Managed-default | Self-host alternative | Upgrade trigger |
|---|---|---|---|
| Compute orchestration | ECS Fargate (managed control plane, no fixed-cost cluster fee) | EKS / self-hosted Kubernetes | Polyglot service stack; service mesh; multi-team IaaS-style platform; autoscaling beyond Fargate's per-task model |
| VPN gateway | AWS Client VPN endpoint (managed, IAM-integrated, cert rotation, multi-AZ HA) | NetBird self-hosted (Berlin-based) / hand-rolled WireGuard | Non-AWS deployment (e.g., IONOS — see ADR-0005); EU sovereignty forbids US-headquartered managed services; 30+ concurrent users where Client VPN endpoint cost (~$1,400/mo at 30 users + 2 AZ) starts to dominate; high-throughput tunnels where the managed service adds latency budget |
| Container runtime | ECS Fargate (capacity provider) | EC2 with self-managed runtime; bare metal | Spot pricing / GPU workloads; resource ceilings beyond Fargate |
| Secrets | AWS Secrets Manager (RDS managed master password, KMS-backed) | HashiCorp Vault self-hosted; SOPS+age | Multi-cloud / non-AWS; rotation policies beyond Secrets Manager primitives; very high secret count where Vault namespacing is cheaper |
| Container registry | ECR (immutable tags, scan-on-push) | Self-hosted Harbor; quay.io | Multi-cloud reach; paid Harbor features (project-level RBAC depth) |
| Reverse proxy / LB | ALB (internal) | nginx / Envoy / HAProxy on EC2 | Layer-7 routing complexity beyond ALB; protocol that ALB does not speak |

The case-study deliverable picks the **left-most column for every row**. Each Phase 2 runbook documents the upgrade path for one or more rows: the cross-cloud migration runbook (ADR-0012) addresses "no managed Client VPN equivalent on IONOS"; the multi-region scaling runbook pre-supposes ECS Fargate as the orchestration layer being scaled.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Self-host every layer from day one ("we'll need it eventually so build it now") | Pays operational cost upfront for capabilities the case-study scope does not need. Contradicts ADR-0003 (PoC scope, prod hygiene). The Phase 2 runbooks document the upgrade path so capability is demonstrable without capability cost. |
| Make the principle implicit (each tool decision its own ADR, no overarching pattern) | Reader has to re-derive the pattern from scattered ADRs. Capturing the discipline once explicitly lets new tool decisions inherit the same reasoning template. |
| Prefer self-host when the managed offering has any cost | "Free" self-hosting still pays in operational time; managed services trade money for engineer hours. The right axis is total cost of operation, not AWS line-item cost. |
| Always pick whichever the customer is already using | Customer cloud preference matters but does not override the managed-default rule within their cloud. On AWS pick ECS Fargate; on IONOS pick Managed K8s — see migration runbook. |
| Hand-rolled "lite" alternatives (write your own VPN gateway, your own container scheduler) | Reinvents wheels at the bottom of the stack; no operational track record; raises liability. Either pick managed (default) or pick the battle-tested self-host (NetBird, K8s) — never roll your own. |

## Consequences
- Each tool decision in this repo (and future case-study cycles via the template reuse pattern in ADR-0004) inherits the managed-default rule without restating it. New tool decisions can cite this ADR and supply the trigger conditions inline rather than re-deriving the principle.
- The deliverable's cloud Terraform composition is consistent across all infrastructure layers — there is no "we managed this layer but self-hosted that one" inconsistency for a reviewer to catch.
- The Phase 2 runbooks (cross-cloud migration ADR-0012, multi-region scaling ADR-0007) are the upgrade catalogue. A reviewer asking "what would scale demand?" sees the same agent-executable schema, a different mapping table, and exact trigger conditions — all framed by this ADR.
- Hightower's Kubernetes philosophy becomes a first-class principle the repo is operated by, rather than an aphorism quoted in passing.
- Future cycles for buyers without managed cloud (e.g., on-prem, IONOS-only) automatically inherit "use that cloud's managed primitives where available; self-host where not", rather than "always self-host because it's portable" — defends against premature self-hosting.
- Cost analysis becomes traceable: when a reader asks why X is managed-default, the answer is the relevant trigger column row, not "we couldn't be bothered to self-host."

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene — supplies the calibration for "scale not yet met")
- ADR-0006 (VPN three-tier — gets re-framed by this ADR; left-column entry is Client VPN endpoint)
- ADR-0010 (VPN ownership — production reality clarifies that even the managed default is consumed at the platform layer, not provisioned at the app layer)
- ADR-0012 (migration runbook spec — Phase 2 upgrade path catalogue)
- ADR-0015 (no K8s, no real apply — left-column entry is ECS Fargate)
- ADR-0017 (prime computation strategy — separate-domain example of "use the simpler primitive until performance demands the upgrade")
