# terraform/bootstrap — deployment prerequisites

This module is **not** part of the case-study deliverable. It provisions the
state backend + the governed-org CI deploy identity that the main composition
depends on. It was reconciled to the live governed-staging account by ADR-0052
(the live resources were break-glass-seeded, then imported here).

## What it manages

| Resource | Purpose | ADR |
|---|---|---|
| S3 bucket `aegis-enclave-tfstate-<env>-<account_id>` (versioned, encrypted, public-access-blocked) | State backend for `terraform/main.tf` | 0025 / 0052 |
| DynamoDB table `aegis-enclave-tflock` (`PAY_PER_REQUEST`, PITR) | State lock — prevents concurrent applies | 0025 |
| IAM role `gh-tf-apply-enclave` + scoped inline policy + `PowerUserAccess` | Governed-org CI deploy identity; in the SCP `gh-tf-*` carve-out | 0051 |

## What it references but does NOT manage

| Resource | Why referenced, not managed |
|---|---|
| GitHub OIDC provider `token.actions.githubusercontent.com` | A per-account **singleton**, owned by the aegis **landing-zone** and shared by every repo's CI roles. The enclave looks it up via `data.aws_iam_openid_connect_provider.github` so an enclave `destroy` can never delete it out from under platform-aws / landing-zone (ADR-0052). |

The read-only PR-plan role that ADR-0026 designed is **de-instantiated** — it was
never wired in this account (`.github/workflows/terraform-plan.yml` gates its
cloud-plan job on `vars.AWS_TF_PLAN_ROLE_ARN`, which is intentionally unset). Its
definition lives in this module's git history; re-add it + break-glass `apply` to
re-enable (ADR-0052).

## Why a separate module

The state backend cannot live in the state file it manages — that would be
self-referential (chicken-and-egg). So this module runs with a **local
backend**, persists its own small state file under `terraform/bootstrap/`
(gitignored), and provisions the backend the main composition then uses.

The CI apply role piggybacks on this module: same lifecycle (provisioned once,
rarely touched, a prerequisite for any deploy), same operator, same local state.

## First-time provisioning (a clean account)

In a clean, ungoverned account a forker applies the whole module directly:

```bash
aws sso login --profile <profile>            # any profile with admin scope
cd terraform/bootstrap
AWS_PROFILE=<profile> terraform init
AWS_PROFILE=<profile> terraform apply
AWS_PROFILE=<profile> terraform output
#   tfstate_bucket               = "aegis-enclave-tfstate-staging-<account_id>"
#   tflock_table                 = "aegis-enclave-tflock"
#   gha_terraform_apply_role_arn = "arn:aws:iam::<account_id>:role/gh-tf-apply-enclave"
```

In the **governed aegis org**, `iam:CreateRole` for the apply role is blocked for
a human PlatformAdmin by the SCP `deny-iam-privilege-escalation`; seed the role
once via the `aegis-emergency-break-glass` role, then import (see "Reconciling on
a fresh machine" below).

## After bootstrap — wire into the main composition

The CI workflows generate `terraform/backend.tf` from the `AWS_TF_STATE_BUCKET`
repo variable (the committed `main.tf` stays backend-less for forkers). Set the
repo variables:

```bash
gh variable set AWS_TF_STATE_BUCKET   --body "aegis-enclave-tfstate-staging-<account_id>"
gh variable set AWS_TF_APPLY_ROLE_ARN --body "arn:aws:iam::<account_id>:role/gh-tf-apply-enclave"
gh variable set AWS_REGION            --body "eu-central-1"
```

`cloud-apply.yml` / `cloud-destroy.yml` then assume `gh-tf-apply-enclave` via
OIDC. The read-only PR-plan path stays dormant until `AWS_TF_PLAN_ROLE_ARN` is
set (it is not, by design).

## Local state file — what to do with it

The bootstrap's own state lives at `terraform/bootstrap/terraform.tfstate`,
**gitignored** (`terraform/*.tfstate`; verify with `git status`). It holds only
resource IDs / ARNs — no secrets.

1. **Keep it on the operator machine** — fine for solo scope; re-running
   `bootstrap` against existing state is idempotent.
2. **Encrypt + back it up** for team-shared scenarios (`gpg -c …`).

Losing it makes the bootstrap's resources "unmanaged" (they still exist; Terraform
just forgets them) — recover by re-import, below.

## Reconciling on a fresh machine (or after losing local state)

The live resources exist; rebuild the local state by importing them (read-only
against the cloud). This is exactly the ADR-0052 reconcile:

```bash
cd terraform/bootstrap
AWS_PROFILE=<profile> terraform init
B=aegis-enclave-tfstate-staging-<account_id>
terraform import aws_dynamodb_table.tflock aegis-enclave-tflock
terraform import aws_iam_role.gha_terraform_apply gh-tf-apply-enclave
terraform import aws_iam_role_policy.gha_apply_iam gh-tf-apply-enclave:gh-tf-apply-enclave-iam-scoped
terraform import aws_iam_role_policy_attachment.gha_apply_poweruser gh-tf-apply-enclave/arn:aws:iam::aws:policy/PowerUserAccess
terraform import aws_s3_bucket.tfstate "$B"
terraform import aws_s3_bucket_versioning.tfstate "$B"
terraform import aws_s3_bucket_server_side_encryption_configuration.tfstate "$B"
terraform import aws_s3_bucket_public_access_block.tfstate "$B"
terraform plan    # expect 0 to add / 0 to destroy
```

The OIDC provider is **not** imported (it's a data source). `terraform plan` may
show benign in-place drift (tags, PITR, description) if the live resources were
hand-seeded; converging it writes IAM on a `gh-tf-*` role, so run that `apply` via
break-glass, not the human PlatformAdmin path.

## Teardown

Abandoning the deployment:

```bash
# 1. Teardown the main composition first (release the state lock)
cd .. && AWS_PROFILE=<profile> terraform destroy

# 2. Empty the versioned state bucket (destroy needs an explicit empty)
AWS_PROFILE=<profile> aws s3 rm "s3://$(terraform -chdir=bootstrap output -raw tfstate_bucket)" --recursive

# 3. Teardown bootstrap (break-glass in the governed org — it deletes the IAM role)
cd bootstrap && AWS_PROFILE=<break-glass-profile> terraform destroy
```

Order matters — destroying bootstrap first leaves the main composition without a
backend to track its own destroy. The OIDC provider is **untouched** by this
teardown (data source); deleting `gh-tf-apply-enclave` removes the CI deploy
identity, so re-seed it via break-glass if you redeploy.
