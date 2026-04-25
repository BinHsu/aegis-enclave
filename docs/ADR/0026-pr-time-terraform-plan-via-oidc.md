# ADR-0026: PR-time Terraform plan via GitHub Actions OIDC

## Status
Accepted (2026-04-25)

## Context
Phase 2 (per ADR-0023, ADR-0024, ADR-0025) makes a real `terraform apply` possible from the operator's laptop. The next maturity step is **Phase 2.5** — making `terraform plan` run automatically on every PR that touches `terraform/**`, so reviewers see infrastructure diffs alongside code diffs.

This is a sweet spot for an aegis-style deliverable:
- **Read-only** — plan never mutates resources, only reports what apply would do.
- **High demo value** — a recruiter or reviewer who clicks a PR sees `Plan: 23 to add, 0 to change, 0 to destroy` rendered inline. That's the artefact-level evidence ADR-0013 calibrates for.
- **Low blast radius** — even a misconfigured PR plan can only fail; it cannot break `main` or AWS state.

The cost is GitHub Actions minutes (~2 min/run, free-tier comfortable) plus the IAM trust scope. Both are tractable.

What this ADR is **not**: a path to CI-driven `terraform apply`. Auto-apply on merge is explicitly Phase-3 territory (see ADR-0023 § Future direction) — it carries a much larger blast-radius envelope (a faulty merge can mutate prod) and a maintenance surface (Terraform state corruption from CI flakes, OIDC drift) that a one-deliverable case study does not justify.

## Decision

**Add `.github/workflows/terraform-plan.yml`** that runs on every PR touching `terraform/**`. The workflow:

1. Triggers on `pull_request` with `paths: terraform/**` and the workflow file itself.
2. Skips cleanly when `vars.AWS_TF_PLAN_ROLE_ARN` is empty (Phase 1 default).
3. When the variable is set, assumes the role via GitHub OIDC, runs `terraform init` + `validate` + `plan`, posts the plan output as a PR comment.

**Add the OIDC trust + IAM role to `terraform/bootstrap/`** (alongside the state backend it shares a lifecycle with):

- `aws_iam_openid_connect_provider` for `token.actions.githubusercontent.com`
- `aws_iam_role` with trust scoped to `repo:BinHsu/aegis-enclave:pull_request` and `repo:BinHsu/aegis-enclave:ref:refs/heads/main`
- AWS-managed `ReadOnlyAccess` policy attached
- Custom policy granting `s3:GetObject/PutObject/ListBucket` on the state bucket and `dynamodb:GetItem/PutItem/DeleteItem` on the lock table only — this is the only place the role can write

When the bootstrap module is run, the operator captures the role ARN from `terraform output gha_terraform_plan_role_arn` and publishes it as a GitHub repository variable:

```bash
gh variable set AWS_TF_PLAN_ROLE_ARN \
   --body "arn:aws:iam::123456789012:role/aegis-enclave-gha-terraform-plan"
gh variable set AWS_REGION --body "eu-central-1"
```

That single variable assignment is the activation switch for the workflow.

## Trust scope analysis

The IAM role's trust policy uses three independent constraints to bound who can assume it:

| Constraint | What it does | Failure mode if missing |
|---|---|---|
| `Federated: <github-oidc-provider-arn>` | Only tokens issued by GitHub's OIDC provider can be presented. | Anyone with valid AWS-side STS access could assume directly. |
| `aud == sts.amazonaws.com` | The token's audience claim must match. | Tokens issued for other audiences (other AWS roles) could cross over. |
| `sub StringLike repo:BinHsu/aegis-enclave:pull_request` (or `:ref:refs/heads/main`) | The token must come from this repo, on a PR or main-branch event. | **Critical** — without this, ANY GitHub repo's Actions could assume the role. |

The `sub` claim is the primary repo-binding control. It can be tightened further (specific PR authors, specific branches, specific environments) at the cost of complexity. For Phase 2.5 I scope to "this repo, PR or main" — sufficient for solo operation.

The role's permissions are then bounded twice:

1. `ReadOnlyAccess` (AWS managed) — allows describing every resource type that `terraform plan` refreshes against. Does not allow `Create`, `Delete`, `Modify`, `Update`, `Put` outside the second policy below.
2. Scoped state-access policy — allows `s3:GetObject/PutObject/ListBucket` on **only** the state bucket, and `dynamodb:GetItem/PutItem/DeleteItem` on **only** the lock table. `terraform plan` acquires the lock and may write a refreshed state on drift; both are required for plan to function correctly.

Net: the role can read everything in the AWS account, can lock the state, can write a refreshed state, and cannot do anything else. A compromised role token cannot create, modify, or destroy any case-study resource — the worst it could do is block `apply` by holding the lock (recoverable via `terraform force-unlock`).

## Plan inputs — what tfvars get used

The workflow plans against `terraform.tfvars.example` (committed to the repo with placeholder ACM ARNs). This is **deliberately a syntax + composition plan**, not a real-state diff:

- The example tfvars passes Terraform's variable validation.
- The placeholder ARNs are accepted as strings — Terraform doesn't validate cert ARN existence at plan time (no `data.aws_acm_certificate` lookup in main.tf).
- The output shows what `apply` would do **if those ARNs were valid**.

For a real-state diff (Phase 2), the operator runs `terraform plan` locally with their real `terraform.tfvars`. The CI plan is for "did the PR's HCL parse and compose without error" — closer to a typecheck than a deployment dry-run.

When that limitation becomes binding (operator wants real diffs reviewable on PR), the upgrade is one of:

- **Store `terraform.tfvars` content in AWS SSM Parameter Store**, fetch in the workflow before plan. Operator updates SSM when tfvars changes. Cleanest from a security perspective.
- **Encode tfvars as GitHub repository secrets**, render to a tfvars file in the workflow. Faster to set up but mixes secret management between two systems.
- **Skip CI plan, rely on local plan**. Honest fallback if neither above is worth the friction.

The workflow has a hook (a `TFVARS_FILE` extension point in the plan step) for the SSM-loaded variant once the upgrade is needed.

## Consequences

**Positive:**
- PRs touching infrastructure get inline plan output. Reviewer sees `Plan: 23 to add, 0 to change, 0 to destroy` without leaving GitHub.
- OIDC short-lived tokens replace any need for long-lived AWS access keys in CI.
- Trust scope is tight enough that a role compromise has bounded blast radius.
- Workflow is no-op until the operator opts in (sets the repo variable), so committing this in Phase 1 is safe — CI minutes are not spent until the bootstrap is run.

**Negative:**
- Phase-1 plan output is "did the HCL compose" only, not real diff. Reviewers familiar with Terraform CI may expect more.
- OIDC trust is a long-lived configuration in AWS. If the GitHub repo is renamed, the trust must be updated. If this repo's ownership transfers, the OIDC trust must be reissued.
- Plan output can be huge for a stack of this size (50+ resources). The workflow truncates at 60k chars (GitHub's PR-comment limit is 65k); full output stays in the job log.

## Alternatives considered

**A. Auto-apply on merge to main (full GitOps).** **Rejected** for case-study scope. Auto-apply on a multi-AZ RDS stack means a bad merge can flap database resources costing real money. The maintenance surface (state corruption, drift detection, rollback automation) is large. ADR-0023 § Future direction documents this as Phase 3.

**B. Use long-lived IAM access keys stored as GitHub Secrets.** **Rejected.** OIDC short-lived tokens are the modern default; long-lived keys have a known leak-blast-radius problem and require periodic rotation. The setup effort is comparable.

**C. Run `terraform plan` only on push-to-main, not on PR.** **Rejected.** PR-time plan is the demo-value differentiator — that's where reviewers see the impact before merge. Push-to-main plan would only catch divergence post-fact.

**D. Use `actions/checkout` with `fetch-depth: 0` and run `tflint` / `tfsec` alongside plan.** **Deferred to Phase 2.5+.** Worth doing once plan is stable; not strictly required for the read-only diff goal.

**E. Comment plan as a sticky comment (update existing rather than re-creating).** **Deferred.** Marketplace actions like `marocchino/sticky-pull-request-comment` exist but introduce a third-party dependency. The simple `createComment` approach is honest about each PR push triggering a fresh plan; the trade-off is comment proliferation on long PRs.

## Implementation notes

The workflow is in `.github/workflows/terraform-plan.yml` and is gated on `vars.AWS_TF_PLAN_ROLE_ARN` so it commits safely without breaking CI. The bootstrap module wiring sits in `terraform/bootstrap/main.tf` (the OIDC provider + IAM role + policies were added there alongside the S3/DynamoDB resources from ADR-0025 — they share a lifecycle).

To activate post-bootstrap:

```bash
cd terraform/bootstrap && terraform output -raw gha_terraform_plan_role_arn
gh variable set AWS_TF_PLAN_ROLE_ARN --body "<role-arn-from-output>"
gh variable set AWS_REGION --body "eu-central-1"
# Open a PR touching terraform/ — the workflow runs, posts plan as comment.
```

To deactivate:

```bash
gh variable delete AWS_TF_PLAN_ROLE_ARN
# Workflow now skips on every PR. Role still exists in AWS — destroy via
# `terraform destroy` in the bootstrap module if no longer needed.
```

## Related
- ADR-0023 — auto-scaling deferred (this ADR's sibling: same "Phase 2 unblock" theme)
- ADR-0024 — VPN cert provisioning (sibling)
- ADR-0025 — state backend (the backend this workflow plans against)
- ADR-0015 — Phase-2 supersession block (the umbrella under which 0023-0026 sit)
