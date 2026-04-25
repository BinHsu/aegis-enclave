# ADR-0011: Constrain the VPN topology to hub-and-spoke; mesh out of scope

## Status
Accepted (2026-04-25)

## Context
The VPN tools considered in this repo (WireGuard for the demo, AWS Client VPN for cloud, NetBird as the self-hosted alternative — see ADR-0006) all *can* operate in mesh mode. NetBird and Tailscale in particular market themselves as "peer-to-peer mesh" overlay networks. That capability is real, and it's also the wrong default to inherit.

Mesh is a **capability**, not a **requirement**. The ACL is the actual topology decision.

The workload here:

- **Operators** (humans, ground-station hosts) connect to the cloud control plane to submit prime ranges and read audit records.
- **Ground stations** (in the production architecture) connect to the cloud control plane to push telemetry / receive commands.
- **Neither operators nor ground stations have a business need to communicate with each other peer-to-peer.**

Allowing client-to-client connectivity adds attack surface (compromise of one client gains lateral movement to other clients) without a single business use case. It also complicates the ACL — every client pair becomes a policy decision instead of one allow-list rule pointing at the gateway.

The right call is to pick the topology that matches the workload and constrain the tool's capability to fit, rather than letting the tool's default capability shape the topology.

## Decision
The VPN topology is **hub-and-spoke**. A single VPN gateway terminates client connections; clients do not connect to each other.

When using a mesh-capable tool (NetBird in the cross-cloud target), the NetBird ACL is configured to enforce hub-and-spoke behaviour: clients can reach the gateway / control-plane subnet, and nothing else. The mesh capability is constrained by policy.

Multi-hub regional topology (one hub per region, hub-to-hub backbone) is out of scope under ADR-0007 (single-region) and lives in the Phase 2 scaling runbook.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Full mesh (every client can reach every other client) | No business need. Expanded attack surface — one compromised client gains lateral movement. ACL becomes a per-pair policy matrix instead of one allow-list. |
| Partial mesh (selected client-to-client paths) | Complexity without clear benefit. If a real use case emerges later, the ACL can be selectively relaxed for that pair. Premature flexibility is just complexity. |
| Multi-hub regional topology | Out of scope under ADR-0007 (single-region Phase 1). Belongs in the Phase 2 scaling runbook as a multi-region extension, not in the Phase 1 deliverable. |
| Let the tool's mesh default decide | Tool capability is not the same as architectural requirement. Letting the default shape the topology inverts the responsibility — the topology should drive the policy, not the other way around. |

## Consequences
- **ACL stays simple.** Client allow-list → gateway DNS / IP only. One rule, easy to review.
- **Attack surface is minimised.** Compromise of one client doesn't grant lateral movement to other clients.
- **Compatible with site-to-site VPN extensions.** Each ground station integrates as a "spoke" to the cloud "hub" without changing the topology model.
- **Topology choice is independent of tool choice.** NetBird's mesh capability is constrained by policy to the topology that actually fits the workload. The same ACL pattern applies if the tool is swapped (WireGuard hub, AWS Client VPN, NetBird, Tailscale).
- **Phase 2 path is documented.** Multi-hub regional topology lives in the scaling runbook, not in Phase 1, so the upgrade conversation is anchored when it happens.

## Related ADRs
- ADR-0006 (VPN three-tier story — WireGuard demo / managed cloud / self-hosted NetBird)
- ADR-0010 (VPN ownership boundary — application vs platform team)
