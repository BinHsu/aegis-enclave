# ADR-0005: AWS as deployment target; cross-cloud as runbook, not Terraform

## Status
Accepted (2026-04-25)

## Context
The case-study brief lists "AWS or IONOS Cloud" as recommended-but-not-mandatory cloud targets. The deliverable must include cloud-side architecture and migration story, but the 22-hour budget (ADR-0028, originally 15h per ADR-0002) does not stretch to a credible production deployment on a cloud the candidate has no operational receipts for.

The candidate's production AWS receipts live in the `aegis-aws-landing-zone` portfolio repo — multi-account governance, VPC patterns, Terraform module composition. There is no equivalent IONOS production experience. Two failure modes follow:

1. **Faking IONOS Terraform** (writing provider blocks against IONOS docs without ever applying) produces a fragile artifact. A senior reviewer who knows IONOS spots the gap in minutes — wrong resource arguments, missing edge cases, plausible-looking but unrun code. The deliverable then signals shallow knowledge across both clouds rather than depth in one.
2. **Real IONOS deployment** would require absorbing IONOS provider quirks, account setup, and IAM model. Honest estimate: 6–8h. That consumes the entire AWS budget.

Skipping the cloud-side entirely is also rejected — the brief asks for "deployment scripts," and a markdown-only deployment guide reads as evasion.

The deliverable needs a structure that puts depth where the candidate has it, and structured intent where the candidate doesn't claim expertise.

## Decision
Deploy the cloud-side architecture to AWS in Terraform code using community modules (see ADR-0015 for `plan`-only posture, ADR-0016 for module choice). Cross-cloud migration to alternative providers — IONOS being the named example — is delivered as an agent-executable runbook (`docs/migration_runbook.md`), not as parallel Terraform code per cloud.

The runbook structure (see ADR-0012) carries the architectural thesis: a service-mapping table at the top, then cloud-agnostic step specs (precondition / action / verify_cmd / expected_output / on_failure / human_gate). The mapping table is the only destination-specific artifact; everything else is invariant across destinations.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Fake IONOS Terraform alongside AWS | ~2h to write provider blocks against IONOS docs without ever applying; dishonest, fragile, signals shallow IONOS knowledge to anyone reading carefully. |
| Real IONOS deployment alongside AWS | Out of budget; no production IONOS receipts to debug provider quirks against; doubles cloud-side time cost. |
| Cloud-agnostic Terraform with conditionals | Complexity exceeds value at this scope. Conditional Terraform reads worse than two clean codebases and still doesn't compile without per-cloud testing. |
| Skip cloud-side, ship markdown deployment guide only | Brief asks for "deployment scripts." A pure-markdown answer reads as deflection. |
| AWS-only Terraform, no migration story | Ignores the brief's explicit "AWS or IONOS" framing; misses the chance to demonstrate cloud-portability thinking. |

## Consequences
- AWS Terraform is receipt-grade: community modules, real-world composition patterns, `terraform plan` output verifiable against the design doc.
- IONOS migration is architectural-thesis grade: an agent-executable spec with a service-mapping table, not an unrun Terraform file. The reviewer reads structured intent, not faked code.
- The runbook format is portable. The same spec works for AWS → GCP, AWS → Azure, AWS → on-prem. Phase 2 reusability across migration targets falls out for free (see ADR-0007's scaling runbook for the same pattern applied to a different axis).
- The deliverable's posture is consistent: real receipts where the candidate has them, structured plans where the candidate doesn't claim expertise. A senior reviewer reads this as judgement, not evasion.
- IONOS-specific implementation effort is deferred to whichever party actually executes the migration (the buyer's team, an AI agent, or a follow-up engagement). The runbook gives them a starting point without pretending the work is already done.

## Related ADRs
- ADR-0006 (VPN three-tier story — including the AWS Client VPN endpoint vs NetBird sovereignty alternative that the runbook leans on)
- ADR-0012 (migration runbook agent-executable spec format)
- ADR-0015 (no real `terraform apply` — the AWS code is `plan`-only)
- ADR-0016 (community modules choice for the AWS Terraform composition)
