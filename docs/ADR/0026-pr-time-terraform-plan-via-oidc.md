# ADR-0026: PR-time Terraform plan via GitHub Actions OIDC

## Status
Accepted (2026-04-28)

## Context

This case-study scope intentionally limits CI/CD to plan-only OIDC. A production deployment — multi-environment account setup, branch-protected apply gates, AWS Organizations / IAM Identity Center wiring, account factory provisioning — requires architectural depth beyond a single-repo deliverable. For that depth, see `aegis-aws-landing-zone` (sister repo in the aegis-* portfolio). The OIDC apply-via-merge production extension lives in `production_adoption.md` § OIDC apply at production scale.

`terraform apply` for the case-study cycle is operator-driven via `make cloud-up` against a personal AWS account. The verification window is one-shot ≤ 3 h apply-then-destroy, not a sustained CI gate. PR-time `plan` covers the case-study need (reviewable infrastructure diff alongside code diff); apply via merge would carry a much larger blast-radius envelope (state corruption from CI flakes, drift handling, rollback automation, environment promotion) that a single-repo deliverable does not justify.

## Decision

**`.github/workflows/terraform-plan.yml`** runs on every PR touching `terraform/**`:

1. Triggers on `pull_request` with `paths: terraform/**` and the workflow file itself.
2. Skips cleanly when `vars.AWS_TF_PLAN_ROLE_ARN` is empty (no-op default for forks that haven't bootstrapped).
3. When set: assumes the role via GitHub OIDC, runs `terraform init` + `validate` + `plan`, posts plan output as a PR comment.

**OIDC trust + IAM role** in `terraform/bootstrap/`:

- `aws_iam_openid_connect_provider` for `token.actions.githubusercontent.com`
- `aws_iam_role` with trust scoped to:
  - `Federated: <github-oidc-provider-arn>`
  - `aud == sts.amazonaws.com`
  - `sub StringLike repo:BinHsu/aegis-enclave:pull_request` and `repo:BinHsu/aegis-enclave:ref:refs/heads/main`
- AWS-managed `ReadOnlyAccess` policy attached
- Custom policy granting `s3:GetObject/PutObject/ListBucket` on the state bucket only and `dynamodb:GetItem/PutItem/DeleteItem` on the lock table only — the only writes the role can issue

After bootstrap, the operator publishes the role ARN as a GitHub repo variable:

```bash
gh variable set AWS_TF_PLAN_ROLE_ARN --body "$(terraform output -raw gha_terraform_plan_role_arn)"
gh variable set AWS_REGION --body "eu-central-1"
```

The role can read everything in the account, can lock the state, can write a refreshed state, and cannot do anything else. A compromised role token's worst case is blocking apply by holding the lock (recoverable via `terraform force-unlock`).

## Alternatives Considered

| Alternative | Industry context |
|---|---|
| Long-lived IAM access keys stored as GitHub Secrets | Rotation hell + supply-chain attack surface (key disclosure via leaked logs / forks). OIDC short-lived tokens are the modern default. |
| Self-hosted GitHub Actions runner with IAM instance profile | Right call when the runner needs to live inside the VPC (e.g., access internal-only endpoints during plan). Adds runner lifecycle + capacity. Out of scope at this case-study size. |
| Atlantis / Terraform Cloud SaaS | Mature multi-env apply orchestration. Right call for orgs running 10+ stacks; overkill for a single-repo deliverable. |
| Skip CI plan, rely on local `terraform plan` | Honest fallback if the PR review surface is small. PR-time inline plan is the demo-value differentiator vs local-only. |
| Apply on merge to main (full GitOps) | Production extension, not case-study scope. See `production_adoption.md` § OIDC apply at production scale. |

## Consequences

- **PR diff includes infrastructure diff.** Reviewer sees `Plan: 23 to add, 0 to change, 0 to destroy` inline.
- **OIDC short-lived tokens** replace any need for long-lived AWS keys in CI.
- **No-op until opted in.** Workflow skips when the repo variable is empty — committing the workflow into a fresh fork is safe.
- **Plan input is `terraform.tfvars.example`** (placeholder ARNs that satisfy type system + composition). Real-state diff requires local plan with the operator's tfvars; the CI plan is closer to a typecheck than a deployment dry-run. Forkers wanting real-state diff have a hook in the workflow (`TFVARS_FILE` extension point) for SSM-loaded tfvars — production extension.
- **Plan output truncates at 60k chars** (PR comment limit ~65k); full output stays in the job log.

## Related ADRs
- ADR-0025 (Terraform state backend — the S3 + DynamoDB the OIDC role accesses)
- ADR-0036 (image tag git SHA + immutable ECR — same supply-chain hygiene posture)
- ADR-0039 (supply-chain rigor — exact-pin / lock / signed-source defaults; OIDC short-lived tokens fit the same posture)
