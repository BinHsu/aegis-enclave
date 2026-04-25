# ADR-0006: VPN three-tier story — Client VPN endpoint primary, NetBird sovereignty alternative, WireGuard demo plumbing

## Status
Accepted (2026-04-25)

## Context
The deliverable touches three different VPN concerns, and conflating them produces either an unrealistic local demo or operational debt in the cloud architecture.

- **Local Task 2 demo** must run inside Docker Compose. AWS Client VPN endpoint is a regional managed AWS service — it cannot run locally. The local demo needs a self-contained VPN gateway container.
- **Cloud production primary** needs a cloud-shaped answer. Hand-rolling WireGuard on EC2 in Terraform means owning key rotation, ACLs, identity binding, audit logs, and HA — all things AWS already manages behind Client VPN endpoint.
- **Sovereignty / non-AWS alternative** is required because IONOS (one of the brief's recommended cloud targets) has no managed VPN endpoint equivalent, and because EU-sovereignty buyers in regulated industries weight cloud independence heavily.

Cost analysis for AWS Client VPN endpoint at typical team scale: ~$0.10/hr per subnet association + ~$0.05/hr per connected user. With 30 users, 2 AZ associations, 24/7 operation, monthly cost lands near $1,400 — roughly $16k/year. NetBird self-hosted (Berlin-based, WireGuard-mesh control plane, EU-sovereign) runs on a `t3.micro` for ~$8/month at the same scale: ~170× lower TCO. Cost is the substantive driver alongside sovereignty, not just political framing.

A single VPN tool stretched across all three concerns answers none of them well. The deliverable needs three deliberate choices.

## Decision
Three distinct VPN concerns, each with a deliberate answer:

| Tier | Tool | Role |
|---|---|---|
| Local Task 2 demo | WireGuard container (`linuxserver/wireguard` image) | Self-contained verification mechanism only |
| Cloud production primary | AWS Client VPN endpoint | Default cloud-side VPN gateway — managed, certificate-based authentication, integrates with VPC + IAM |
| Sovereignty / non-AWS alternative | NetBird (Berlin-based, self-hostable, WireGuard mesh control plane) | Recommended when Client VPN endpoint isn't an option (non-AWS clouds), or when its cost / sovereignty profile doesn't fit |

WireGuard's role is demoted to demo plumbing. The design doc and migration runbook treat AWS Client VPN endpoint as the architectural primary; WireGuard appears only in `docker-compose.yml` and the `wireguard/` folder as the Task 2 verification mechanism.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| WireGuard everywhere (local + cloud + production) | Hand-rolling key rotation, ACLs, identity binding, and audit logs in cloud is reinvented work. AWS Client VPN endpoint already provides these as a managed service. |
| AWS Client VPN endpoint locally | Impossible — managed cloud-only service, regional. Cannot run inside Docker Compose. |
| Tailscale (mesh VPN) for sovereignty alternative | US-funded; weak EU-sovereignty signal for buyers in regulated EU industries. NetBird is the Berlin-based, EU-native peer. |
| NetBird everywhere including local demo | NetBird self-hosted requires management server + signal server + dashboard + Coturn. Heavier than `linuxserver/wireguard` for a 2-container demo. Not a time saver. |
| Skip the sovereignty alternative, AWS Client VPN endpoint only | Leaves the cross-cloud migration runbook (ADR-0012) without a non-AWS VPN answer. Misses the chance to demonstrate cost-aware buy-vs-build judgement. |

## Consequences
- The deliverable narrates three deliberate VPN choices, each justified — the senior signal is the differentiation of *concerns*, not picking one tool for all three.
- WireGuard appears in committed code as demo plumbing only. The design doc's VPN architecture section talks about Client VPN endpoint as the cloud primary; the local stack's WireGuard container is presented as a verification mechanism, not the architectural answer.
- Cost analysis (~170× TCO reduction at 30-user scale) drives the NetBird recommendation as much as sovereignty preference. Reviewers reading "we recommend NetBird for IONOS migration" see a cost-aware engineer, not a politically motivated one.
- The migration runbook (ADR-0012) Track 2 covers AWS Client VPN endpoint → NetBird self-hosted, addressing "what if we leave AWS" as an architectural consequence rather than a stance.
- Adding a fourth VPN concern (e.g., site-to-site to a ground station) would warrant a superseding ADR. The current three tiers cover the brief; further tiers are explicitly out of scope.

## Related ADRs
- ADR-0010 (VPN ownership boundary — where the candidate's responsibility ends and the operator's begins)
- ADR-0011 (hub-spoke topology — the cloud-side network shape Client VPN endpoint plugs into)
- ADR-0012 (migration runbook agent-executable spec — Track 2 covers the NetBird migration)
- ADR-0018 (managed-default tool selection — Client VPN endpoint is the managed-default for the VPN-gateway domain)
- ADR-0019 (private-only VPC — completes the network story: this ADR governs ingress, ADR-0019 governs egress)
