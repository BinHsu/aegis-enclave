# ADR-0012: Ship the migration runbook as an agent-executable spec, not parallel Terraform

## Status
Accepted (2026-04-25)

## Context
Brief Task 4 asks for "cloud deployment guidelines and scripts" that explain how the system would be deployed and migrated across clouds. It does **not** ask for parallel Terraform code per destination cloud.

Two failure modes are easy to fall into:

1. **Static markdown runbook** — "step 1: do X, step 2: do Y" — readable but not actionable by an AI agent and not particularly reviewable by a human either. Commodity output.
2. **Full Terraform per destination cloud** — fakeable up to a point, but real cross-cloud Terraform requires real expertise in each cloud's primitives. Faking it is detectable, and the AWS-only target (ADR-0005) is the deliberate scope.

The third path is the differentiator: an **agent-executable spec** with a structured per-step schema. Each step has clear preconditions, declarative actions, verification commands, expected outputs, rollback paths, and a human-gate flag for irreversible operations. AI coding agents (Claude Code, Cursor, etc.) execute this format reliably *only* if the spec is written in agent-executable form — and the same structure is what makes the runbook reviewable by a human engineer.

The format also becomes a **portfolio template**. The same schema retargets any cloud or any axis (region, provider, runtime) by swapping a service-mapping table at the top. The spec is invariant; the mapping is the variable.

## Decision
The migration runbook (`docs/migration_runbook.md`) is an **agent-executable spec** with a structured per-step schema. It is not parallel Terraform code per destination cloud. The Phase 2 scaling runbook (`docs/scaling_runbook.md`, single-region → multi-region) follows the same format.

**Step schema** (every step has):

- `precondition` — what must be true before running
- `action` — described declaratively, not as cloud-specific code
- `verify_cmd` — how to confirm the step succeeded
- `expected_output` — what success looks like
- `on_failure` — rollback or escalation
- `human_gate` (boolean) — flag for steps requiring human approval (destructive or irreversible)

**Top-of-runbook artifact**: a service-mapping table (e.g. `aws.vpc → ionos.datacenter`, `aws.eks → ionos.k8s_cluster`, `aws.client_vpn_endpoint → netbird.gateway`). The mapping is the only destination-specific artifact; the rest of the spec is invariant.

**Two tracks for cross-cloud (Phase 2)**:

- **Track 1 — Application**: VPC → ECS / containers → RDS → IAM → secrets, owned by Application/Cloud team
- **Track 2 — VPN modernisation**: AWS Client VPN endpoint → self-hosted NetBird, owned by Platform/Network team (per ADR-0010)

**Capability gates** (`human_gate: true` is mandatory for):

- Any `*delete*` operation
- Any `terraform destroy`
- Production traffic cutover
- IAM changes
- Cross-region data transfer above a threshold

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Static markdown runbook ("step 1: do X; step 2: do Y") | Not actionable by agents. Less reviewable by humans (no verification or rollback per step). Commodity output — every candidate ships this. |
| Full Terraform code per destination cloud | Requires real expertise per cloud (ADR-0005 explicitly chose AWS-only). Faked Terraform is detectable; real Terraform across N clouds is a multi-week project. |
| Pseudocode runbook (semi-structured but not parseable) | Neither human-friendly nor machine-friendly. Falls between two stools and serves neither audience. |
| Terraform for AWS only + static markdown for everything else | Inconsistent. The runbook shape should match across destinations so the format itself becomes the portable artifact, not the AWS code. |

## Consequences
- **Differentiator artifact.** The runbook is a manifesto centerpiece, not supporting documentation. Reviewers see a format choice that signals AI-augmented operations thinking rather than commodity markdown.
- **Capability gates are explicit.** `human_gate: true` on destructive / irreversible steps demonstrates awareness that AI agents need bounded autonomy — not "agent does everything", not "human does everything".
- **Portable across destinations.** Future cycles reuse the runbook spec format with a different mapping table. The format is a reusable asset; the mapping is the per-cycle variable.
- **Phase 2 scaling runbook proves generalisability.** The single-region → multi-region runbook is a *second instance* of the same format, instantiated against a different axis. Two instances make the format credible; one would just be a one-off.
- **Two-track ownership maps to ADR-0010.** Application track and VPN-modernisation track have different owners in production. The runbook structure makes that boundary visible rather than blurring it.
- **Commits the team to format discipline.** If a future runbook step is written without `verify_cmd` or `on_failure`, it's a regression against this ADR and gets caught in review.

## Related ADRs
- ADR-0005 (AWS as primary target; cross-cloud as runbook)
- ADR-0006 (VPN three-tier story — VPN modernisation track target is NetBird)
- ADR-0007 (single-region; Phase 2 scaling runbook follows same format)
- ADR-0010 (VPN ownership boundary — drives the two-track structure)
