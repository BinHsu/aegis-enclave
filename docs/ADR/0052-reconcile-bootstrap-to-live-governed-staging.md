# ADR-0052: Reconcile the bootstrap composition to the live governed-staging state

## Status
Accepted (2026-06-01)

Supersedes the state-bucket naming in [ADR-0025](0025-terraform-state-backend-s3-dynamodb.md), and the OIDC-provider-ownership + read-only-plan-role-instantiation halves of [ADR-0026](0026-pr-time-terraform-plan-via-oidc.md). Records bringing the [ADR-0051](0051-ci-driven-iam-apply-gh-tf-apply-enclave.md) apply role under IaC management.

## Context

The governed-org deploy campaign (ADR-0050/0051) seeded the deployment prerequisites by hand to get the first CI deploy moving: the `gh-tf-apply-enclave` apply role was created via the `aegis-emergency-break-glass` role (the org SCP `deny-iam-privilege-escalation` blocks a human PlatformAdmin from `iam:CreateRole`), and the S3 state bucket + DynamoDB lock table were seeded with an aws-CLI script. None of these live resources were in any terraform state — the `terraform/bootstrap` composition that *describes* them had never been applied in this account.

That left three gaps between `terraform/bootstrap/*.tf` and reality:

1. **State bucket naming.** ADR-0025 named the bucket `aegis-enclave-tfstate-${random_id.hex}`. The live bucket is `aegis-enclave-tfstate-staging-251774439261` — a deterministic `…-<env>-<account_id>` name from the seed script. Importing the live bucket against the random_id config would have planned a **destroy-and-recreate of the bucket that holds all state**.

2. **OIDC provider ownership.** ADR-0026 declared `aws_iam_openid_connect_provider.github` as an enclave-**managed** resource. But `token.actions.githubusercontent.com` is a per-account **singleton**, created and owned by the aegis **landing-zone** (live tags: `Project=landing-zone-lab`), and shared by every repo's CI roles — the enclave apply role, the platform apply role, and any future federated role all trust this one provider. Managing it from the enclave bootstrap would (a) re-tag shared infra as enclave-owned and (b) let an enclave `terraform destroy` delete the provider out from under every other repo's CI.

3. **Read-only PR-plan role never instantiated.** ADR-0026's `aegis-enclave-gha-terraform-plan` role + its `ReadOnlyAccess` attachment + the scoped state-access policy do not exist live. `.github/workflows/terraform-plan.yml` gates its cloud-plan job on `vars.AWS_TF_PLAN_ROLE_ARN != ''` (a Phase-1 dormant default), and that repo variable is intentionally unset. Keeping these in the composition would make a PlatformAdmin `terraform apply` trip the SCP on `iam:CreateRole`.

The goal: bring the live, enclave-owned prerequisites under IaC so `gh-tf-apply-enclave` is no longer an undocumented hand-seeded role, without claiming shared infra and without a destructive plan.

## Decision

Reconcile `terraform/bootstrap` to live by importing what the enclave owns, referencing what it shares, and removing what was never instantiated.

1. **Import the enclave-owned prerequisites** into the bootstrap's local state (`terraform import`, read-only against the cloud):
   - `aws_s3_bucket.tfstate` (+ versioning, SSE, public-access-block)
   - `aws_dynamodb_table.tflock`
   - `aws_iam_role.gha_terraform_apply` (`gh-tf-apply-enclave`) + its inline scoped IAM policy + the `PowerUserAccess` attachment

2. **Deterministic state-bucket name.** Config becomes `aegis-enclave-tfstate-${var.environment}-${data.aws_caller_identity.current.account_id}` (default `environment = "staging"`), matching live. `random_id.tfstate_suffix` is removed. Deterministic beats random_id: the name is reproducible from `(env, account)` alone, so a re-bootstrap or a forker lands the same bucket without first reading a prior terraform output. **Supersedes ADR-0025's naming.**

3. **OIDC provider as a data source.** `resource "aws_iam_openid_connect_provider" "github"` becomes `data "aws_iam_openid_connect_provider" "github"` (lookup by URL); the apply-role trust and the informational output reference the data source. The provider's lifecycle stays with the landing-zone. **Supersedes ADR-0026's ownership of the provider.**

4. **De-instantiate the read-only PR-plan role.** The plan role + ReadOnlyAccess attachment + state-access policy + attachment + the `gha_terraform_plan_role_arn` output are removed from the composition so `plan`/`apply` are a clean no-op against live. The capability is **not** lost: the design remains in ADR-0026 and this composition's git history, and `terraform-plan.yml`'s gate re-opens the moment `AWS_TF_PLAN_ROLE_ARN` is set. To re-enable, re-add the resources and break-glass `apply` (the human path is SCP-gated by design). **Supersedes ADR-0026's instantiation, not its plan-on-PR intent.**

5. **Residual benign drift converges on a break-glass bootstrap apply.** After import, `terraform plan` shows `0 to add, 0 to destroy` and three in-place changes on the owned resources, all live→config convergence from the hand-seed: the enclave `default_tags` (the seed applied none), `point_in_time_recovery` on the lock table (`false → true`), and the apply-role description text. The apply-role's `assume_role_policy` re-render is cosmetic — the live trust is byte-for-byte semantically identical (`aud`, `repository_id=1220640710`, `sub=repo:BinHsu/*:ref:refs/heads/main`, federated principal). None of the three changes alter a permission, and none are a destroy. They converge on the next bootstrap `terraform apply`, which — because it writes IAM on a `gh-tf-*` role — runs via break-glass, not the human PlatformAdmin path.

> **Executed (2026-06-01).** The convergence was applied as a two-principal targeted apply, because no single principal can write all three: the S3 bucket-tagging + DynamoDB tags/PITR went via PlatformAdmin (`-target=aws_s3_bucket.tfstate -target=aws_dynamodb_table.tflock`; S3/DynamoDB are not SCP-gated), and the role description/tags went via the break-glass role (`-refresh=false -target=aws_iam_role.gha_terraform_apply`; `iam:*` on `role/gh-tf-*`, with `-refresh=false` so terraform never tries to read the bucket/lock with break-glass's IAM-only creds). `terraform plan` is now `No changes` — live == config == state.

## Alternatives Considered

- **Import the OIDC provider too (manage it from the enclave).** Rejected: it is shared, landing-zone-owned infra. A single composition managing an account singletons that other compositions depend on is a cross-repo `destroy` hazard. Data-source reference is the correct ownership boundary.
- **Keep `random_id` naming and import with `terraform state mv`/name juggling.** Rejected: no amount of state surgery makes a `random_id`-derived name equal `…-staging-<account>`; the bucket would still plan a replace. Deterministic naming is both correct and a strict improvement (reproducible).
- **Leave the plan role in config as designed-but-not-yet-applied.** Rejected for the governed account: it yields a non-clean plan and a PlatformAdmin `apply` that half-fails on the SCP. The workflow gate already models "not yet provisioned" cleanly; the role belongs in git history until wired.
- **Reconcile config *down* to live for the cosmetic drift (shorten the description, drop default_tags, disable PITR).** Rejected: config is the canonical source of truth for the enclave-owned resources; the hand-seed's missing tags / PITR are accidental omissions, not intent. Converge live→config on the next break-glass apply instead.
- **A dedicated `terraform/deploy-role` composition holding only the apply role.** Rejected: the apply role, state bucket, and lock table are all bootstrap-tier prerequisites with the same lifecycle and the same operator; splitting them adds a second local state to carry for no isolation benefit.

## Consequences

**Positive**
- `gh-tf-apply-enclave` is now IaC-described and state-managed, not an undocumented hand-seeded role. Its scoped IAM policy is reviewable in `oidc-apply-role.tf` and tracked in state.
- The state backend (bucket + lock) is under the same composition that the rest of the stack's `backend.tf` points at, with a reproducible deterministic name.
- The shared OIDC provider can no longer be re-tagged or destroyed by an enclave operation — the ownership boundary is explicit in code.
- `terraform plan` on the bootstrap is now structurally clean (no creates, no destroys); the only delta is documented benign convergence.

**Negative / costs**
- The bootstrap uses a **local** backend by design (chicken-and-egg, ADR-0025), so the imported state lives on the operator's machine and is gitignored. A fresh machine must re-run the imports listed here (or break-glass `apply` into a clean account) to reconstruct it. This is inherent to a bootstrap tier and is documented in `bootstrap/main.tf`.
- Reaching `plan = 0` requires one break-glass `terraform apply` (the apply-role tags/description are SCP-gated for the human path). Until then the three benign in-place changes persist as documented drift.
- The read-only PR-plan capability is now "re-add from git history + wire the var" rather than "set one variable." Acceptable: it was never wired in this account, and the design is preserved.

## Related ADRs
- [ADR-0025](0025-terraform-state-backend-s3-dynamodb.md) — state backend; this ADR supersedes its bucket naming.
- [ADR-0026](0026-pr-time-terraform-plan-via-oidc.md) — PR-time plan via OIDC; this ADR supersedes its OIDC-provider ownership and the plan-role instantiation, not the plan-on-PR intent.
- [ADR-0050](0050-ipam-aware-vpc-cidr-allocation.md) — IPAM CIDR allocation for the governed deploy.
- [ADR-0051](0051-ci-driven-iam-apply-gh-tf-apply-enclave.md) — the `gh-tf-apply-enclave` apply role this ADR brings under IaC.
