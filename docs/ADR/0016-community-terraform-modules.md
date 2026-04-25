# ADR-0016: Use community Terraform modules; do not hand-roll AWS resources

## Status
Accepted (2026-04-25)

## Context
The Terraform composition for the cloud target (AWS, see ADR-0005) needs a VPC across two AZs, ECS Fargate behind an internal ALB, RDS PostgreSQL, an AWS Client VPN endpoint, ECR, Secrets Manager, and the security groups that wire them together. There are two ways to write this:

1. Hand-rolled HCL — every resource (`aws_vpc`, `aws_subnet`, `aws_route_table`, `aws_nat_gateway`, `aws_internet_gateway`, etc.) declared directly against the AWS provider.
2. Community modules from the [`terraform-aws-modules`](https://registry.terraform.io/namespaces/terraform-aws-modules) namespace — well-established, version-pinned, production-tested compositions of those same primitives.

Hand-rolled Terraform for VPC + subnets + route tables + NAT + IGW is roughly 80 lines of error-prone boilerplate. The community VPC module replaces it with about 10 lines of well-defined inputs and absorbs breaking changes in the AWS provider (the module's own release notes pin compatible provider versions).

Senior reviewers recognise community modules instantly. Using them signals "I don't reinvent wheels"; hand-rolling the same shapes signals "I haven't worked at scale enough to have found these." Modules are also auditable artefacts in their own right — version-pinned, source-readable, with their own ADR-equivalents in the form of release notes.

## Decision
Build the Terraform composition from `terraform-aws-modules/*` registry modules. Hand-rolled HCL is reserved for thin glue between modules. Modules in use:

- `terraform-aws-modules/vpc/aws` — VPC + subnets + NAT + IGW
- `terraform-aws-modules/rds/aws` — RDS PostgreSQL (Multi-AZ standby per ADR-0009)
- `terraform-aws-modules/ecs/aws` + `terraform-aws-modules/alb/aws` — ECS Fargate cluster + internal ALB
- `terraform-aws-modules/security-group/aws` — security group composition
- AWS Client VPN endpoint via the AWS provider directly (no high-quality community module for this resource exists yet, but the resource itself is small)
- ECR repository and Secrets Manager secrets — community modules where mature, otherwise direct provider resources

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Hand-rolled HCL for everything | Reinventing wheels; lower senior-reviewer signal; harder to review per-resource; brittle when AWS provider schema changes. |
| AWS CDK (TypeScript / Python) | Brief asks for Terraform-style deployment; ecosystem fit lower than community Terraform modules; introduces a language runtime where text-config suffices. |
| Pulumi | Same trade-off as CDK — different language, different state model, weaker community-module ecosystem at this scope. |
| Terragrunt for multi-environment composition | Terragrunt's value is multi-environment + state remoting; we have a single environment in Phase 1; over-engineering. |
| CloudFormation | Terraform is industry-standard for multi-cloud and cross-cloud; CloudFormation locks the runbook (ADR-0012) to AWS-only and breaks the cross-cloud invariance the runbook design depends on. |

## Consequences
- Less HCL to write — saves ~30-45 min vs hand-rolled — and the saved time goes into the runbook and the smoke test.
- Reviewer immediately recognises modules from `terraform-aws-modules/*` and skips per-resource inspection — they trust the module's own release process.
- Modules absorb breaking changes in the AWS provider; the module's release pins compatible provider versions, which means the repo's Terraform stays buildable longer without active maintenance.
- The migration runbook (ADR-0012) for cross-cloud destinations references the *same* logical resources — community modules clarify the mapping table because each module corresponds to a recognisable cloud primitive (`vpc/aws` ↔ "VPC equivalent on destination cloud", `rds/aws` ↔ "managed Postgres on destination cloud").
- Trade-off accepted: community modules occasionally expose options the underlying resource doesn't, or hide options the underlying resource does. For the case-study scope this is non-binding; for production use, the team would either pin a known-good module version or fork.

## Related ADRs
- ADR-0005 (AWS as deployment target — the cloud this Terraform composition targets)
- ADR-0015 (no real apply — the code is module-based but not executed against a real account)
