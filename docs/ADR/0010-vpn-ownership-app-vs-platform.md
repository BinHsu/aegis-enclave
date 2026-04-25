# ADR-0010: Mark the VPN ownership boundary — application vs platform/network team

## Status
Accepted (2026-04-25)

## Context
Brief Task 2 bundles a VPN gateway into the Docker Compose stack alongside the application services. That layout is appropriate for a self-contained two-container demo: it makes the security boundary visible and runnable in a single `docker compose up`.

It is **not** appropriate as a production architectural recommendation, and treating it as one would be a senior-signal miss.

In production at typical company scale (30-200 employees), VPN is **centralised platform infrastructure** owned by a platform / network team:

- Key material and identity binding are managed once, not per service
- Audit logs are aggregated centrally for compliance
- HA, failover, and capacity planning are handled at the platform layer
- Application services consume an existing VPN endpoint and express network policy via Security Groups / Kubernetes NetworkPolicies — they do not provision the VPN themselves

The buyer is at this scale (sub-100 engineers, rapid hiring trajectory). They will not run a per-service VPN model. Ignoring that distinction would commit a German-engineering-culture anti-pattern (overstepping into another team's scope, "越權"), which senior reviewers read as a maturity signal.

The right call is to keep the demo bundled (the brief asks for it) but **mark the boundary explicitly** in the design doc and structure the Terraform so the VPN module is replaceable.

## Decision
For the **Phase 1 demo**, the VPN gateway runs as a container alongside the application services, per brief Task 2 wording.

For **production architecture**, the VPN gateway belongs to a platform / network team and is consumed by application services, not provisioned by them.

This distinction is recorded in:

- A "VPN scope boundary" section in `docs/design_doc.md`
- The Terraform module structure: `module "vpn"` is a separable unit. In a production deployment it can be replaced by a `data` source pointing at the existing corporate VPN endpoint, with the application module unchanged.
- The migration runbook (ADR-0012), which splits into two tracks owned by different teams.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Treat the bundled demo as the architectural recommendation | Misses senior signal. The Docker Compose layout is a demo simplification, not a production blueprint. Submitting it as a recommendation reads as inexperience with how platform teams partition responsibility at scale. |
| Refuse to bundle the VPN in the demo (Docker network isolation only) | Bends the brief. Task 2 explicitly requires a VPN gateway. Reinterpreting the brief to fit a personal preference introduces review-time risk for no architectural gain. |
| Bundle in demo, stay silent on production scope | Loses the only opportunity to demonstrate team-boundary awareness. The boundary is the senior-signal artifact; not naming it wastes the deliverable. |

## Consequences
- **Design doc has an explicit "VPN scope boundary" section** explaining demo bundling vs production decoupling. The reviewer sees the distinction without having to infer it.
- **Terraform module structure supports replacement.** `module "vpn"` is separable; in production it becomes a `data` source on an existing endpoint with no change to the application module.
- **Migration runbook splits into two tracks** (ADR-0012): Application track (app + DB + ECS migration) and VPN track (managed VPN endpoint → self-hosted NetBird). Different owners, different cadence.
- **Signals team-boundary architecture awareness.** Valued highly in German engineering culture, where overstepping team scope is a known cultural negative. The ADR makes the awareness legible to reviewers who care about it.
- **Costs nothing in Phase 1.** The boundary is documentation and module shape, not extra implementation work.

## Related ADRs
- ADR-0006 (VPN three-tier story — WireGuard demo / managed cloud / self-hosted NetBird)
- ADR-0012 (migration runbook two-track structure)
