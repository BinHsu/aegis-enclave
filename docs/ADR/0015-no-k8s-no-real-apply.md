# ADR-0015: No Kubernetes manifests; no real Terraform apply for the cloud target

## Status
Accepted (2026-04-25)

## Context
Two scope-temptations sit at the edge of this deliverable: shipping Kubernetes manifests alongside Docker Compose, and running `terraform apply` against a real AWS account to capture screenshots of the deployed system. Both are tempting because both look like "more work, more signal." Both, on inspection, are over-scope.

The brief itself is precise about what's required:

- **Task 2 (orchestration)** says "Docker Compose / Kubernetes" — "or", not "and". One suffices.
- **Task 3 (cloud)** says cloud deployment is "encouraged but not mandatory. **A list of clear instructions would suffice.**" — applying the Terraform is not required.

The Phase 1 calibration is "production-shape, PoC-scale" (ADR-0003). Kubernetes for two services is over-engineering at PoC scale; a real cloud apply produces evidence the brief doesn't ask for, while consuming budget the brief's other deliverables do need.

Senior reviewers recognise scope-honest delivery. Adding K8s and a real apply would be visible as overengineering, not as effort. The differentiator at this scope is the migration runbook (ADR-0012), not a screenshot of a running ECS task.

What we save by not doing K8s: ~1-1.5h cluster setup (kind + Calico CNI for NetworkPolicy support) + manifest writing + debug, plus the cognitive overhead of a second orchestration system in the same deliverable. What we save by not applying Terraform: ~2-2.5h for provider setup, IAM bootstrap, debug, screenshot capture, and teardown — plus AWS account exposure, since every apply leaves state to clean up.

## Decision
Use **Docker Compose only** for orchestration — no Kubernetes manifests. Provide Terraform code for AWS as a **`plan`-only artifact** — no `terraform apply`. The Terraform code is built from community modules (ADR-0016) and is reviewable as code; the runbook (ADR-0012) carries the architectural differentiator. If the buyer asks "could you actually deploy this?", the answer is yes — here's the plan output, here's the runbook — which demonstrates capability without consuming budget on proof.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| K8s manifests + kind cluster | ~1-1.5h with no signal gain at this scope; Docker Compose satisfies the brief; introduces a second orchestration system to maintain. |
| K8s manifests as reference-only (committed but not run) | Still ~30 min to write meaningful manifests; reviewers can't tell whether they actually run, so the artifact is lower-trust than what it replaces. |
| Real AWS apply with screenshots | Brief explicitly optional; ~2-2.5h cost; doesn't differentiate beyond what the runbook already does; leaks account IDs / IPs / ARNs into the repo; leaves AWS state to clean up. |
| EKS instead of ECS Fargate in Terraform | $73/mo control plane fee + complexity; ECS Fargate is the appropriate-complexity managed primitive for case-study scope; EKS is a Phase 2 conversation if the buyer's actual workload demands it. |

## Consequences
- Phase 1 budget stays within 15h (saves ~3-4h vs the maximalist version that ships K8s + a real apply).
- Cloud account exposure minimised — no real state to clean up, no leaked identifiers in committed history.
- The runbook (ADR-0012) carries the architectural differentiator, not the apply screenshot.
- If a reviewer reads the absence of a real apply as "couldn't actually deploy", the cover note + the plan output + the runbook collectively answer that — and the answer is more senior than a screenshot would be: "we deliver code + verifiable plan, not real cloud state, because the brief asks for instructions."
- Trade-off accepted: candidates who run a real apply may produce flashier deliverables. The compensating gain is that the artifact stays scope-honest, time-budget-honest, and account-hygiene-honest.

## Related ADRs
- ADR-0002 (15h time budget — the constraint this decision protects)
- ADR-0003 (PoC-scope, production-hygiene calibration)
- ADR-0012 (migration runbook is the architectural differentiator, not the apply)
- ADR-0016 (community Terraform modules — the code that doesn't get applied)
- ADR-0018 (managed-default tool selection — ECS Fargate is the managed-default for the compute-orchestration domain)
