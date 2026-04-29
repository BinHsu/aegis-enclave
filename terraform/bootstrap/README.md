# terraform/bootstrap — deployment prerequisites

This module is **not** part of the case-study deliverable. It exists to
unblock cloud-acceptance deployment by provisioning the state backend +
GitHub OIDC trust setup that the main composition depends on.

## What it provisions

| Resource | Purpose | ADR |
|---|---|---|
| S3 bucket (versioned, encrypted, public-access-blocked) | State backend for `terraform/main.tf` | 0025 |
| DynamoDB table (`PAY_PER_REQUEST`, PITR enabled) | State lock — prevents concurrent applies | 0025 |
| GitHub OIDC identity provider | Lets GitHub Actions assume an AWS role via short-lived tokens | 0026 |
| IAM role + policies (read-only + scoped state access) | The role `.github/workflows/terraform-plan.yml` assumes | 0026 |

## Why a separate module

The state backend cannot live in the state file it manages — that would be
self-referential (chicken-and-egg). So this module runs with a **local
backend**, persists its own small state file under `terraform/bootstrap/`,
and provisions the backend that the main composition then uses.

The OIDC provider + GHA role piggyback on this module because they have the
same lifecycle: provisioned once, rarely touched, and prerequisites for
the main composition's deployment. Keeping them together means one apply
unblocks everything that the cloud-acceptance flow needs.

## One-time setup

```bash
# 1. Authenticate via SSO (or any AWS profile with admin scope)
aws sso login --profile aegis

# 2. Initialise + apply the bootstrap module (LOCAL backend)
cd terraform/bootstrap
AWS_PROFILE=aegis terraform init
AWS_PROFILE=aegis terraform apply

# 3. Capture outputs
terraform output
#   tfstate_bucket               = "aegis-enclave-tfstate-xxxxxxxx"
#   tflock_table                 = "aegis-enclave-tflock"
#   gha_terraform_plan_role_arn  = "arn:aws:iam::123456789012:role/aegis-enclave-gha-terraform-plan"
```

## After bootstrap — wire into the main composition

**1. Edit `terraform/main.tf`** to uncomment and fill in the `backend "s3"` block:

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers { ... }

  backend "s3" {
    bucket         = "aegis-enclave-tfstate-xxxxxxxx"   # ← from output
    key            = "main/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "aegis-enclave-tflock"             # ← from output
  }
}
```

**2. Re-init the main composition** (Terraform will offer to migrate any
existing local state into S3):

```bash
cd ..
AWS_PROFILE=aegis terraform init
```

**3. Set the GHA role ARN as a GitHub repository variable** so the PR
plan workflow (`.github/workflows/terraform-plan.yml`) can assume it:

```bash
gh variable set AWS_TF_PLAN_ROLE_ARN \
   --body "arn:aws:iam::123456789012:role/aegis-enclave-gha-terraform-plan"
gh variable set AWS_REGION --body "eu-central-1"
```

(The workflow falls back to a no-op if `AWS_TF_PLAN_ROLE_ARN` is unset, so
it's safe to commit before bootstrap; it only "activates" once the
variable is populated.)

## Local state file — what to do with it

The bootstrap module's own state lives at `terraform/bootstrap/terraform.tfstate`.
This file is **gitignored** (the existing `.gitignore` rule
`terraform/*.tfstate` covers nested paths under terraform/ via the
`terraform/.terraform/` family of rules — verify with `git status`).

Two operator-side options:

1. **Keep it on the laptop** — fine for solo case-study scope. Re-running
   `bootstrap` against the existing state is idempotent.
2. **Encrypt and back it up** — for team-shared scenarios, `gpg -c
   terraform/bootstrap/terraform.tfstate` and store in a personal secrets
   vault. Restore before any future `bootstrap` apply.

Losing this state file means the bootstrap module's resources become
"unmanaged" (still exist in AWS, but Terraform doesn't know about them).
Recovery is `terraform import` of the bucket / table / role / OIDC
provider — annoying but not catastrophic.

## Teardown

If deployment is being abandoned and you want to clean up:

```bash
# 1. First teardown the main composition (release state lock)
cd ..
AWS_PROFILE=aegis terraform destroy

# 2. Empty the state bucket (S3 versioning means destroy needs explicit empty)
AWS_PROFILE=aegis aws s3 rm "s3://$(terraform -chdir=bootstrap output -raw tfstate_bucket)" --recursive

# 3. Then teardown bootstrap
cd bootstrap
AWS_PROFILE=aegis terraform destroy
```

Order matters — destroying bootstrap first leaves the main composition
without a backend to track its own destroy.
