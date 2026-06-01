# terraform/bootstrap/main.tf — One-time provisioning of the deployment prerequisites.
#
# What lives here (reconciled to the live governed-staging account by ADR-0052):
#   1. S3 bucket + DynamoDB lock table → state backend for `terraform/main.tf`
#                                        (ADR-0025; deterministic bucket name)
#   2. GitHub Actions OIDC provider    → federation root (ADR-0026)
#   3. gh-tf-apply-enclave APPLY role  → governed-org deploy identity, in the
#                                        SCP `gh-tf-*` carve-out (oidc-apply-role.tf, ADR-0051)
# The read-only PR-plan role (ADR-0026) is intentionally NOT here — de-instantiated
# in the ADR-0052 reconcile (see the note where it used to live, below).
#
# State: this composition uses a LOCAL backend by design (chicken-and-egg — the
# main composition's backend cannot reference the bucket holding its own state;
# ADR-0025 § "Why a separate bootstrap module"). The local terraform.tfstate is
# gitignored and lives on the operator's machine.
#
# How it was reconciled (one-time, ADR-0052): the live resources were
# break-glass-seeded, then `terraform import`-ed into this composition's state so
# `plan` is a no-op. To re-derive on a fresh machine, re-run the imports listed
# in ADR-0052, or break-glass `terraform apply` into a clean account.
#
# Outputs feed: `tfstate_bucket` + `tflock_table` → the CI-generated backend.tf;
# `gha_terraform_apply_role_arn` → the AWS_TF_APPLY_ROLE_ARN repo variable.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aegis-enclave"
      Environment = "bootstrap"
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
      Owner       = var.owner
      Repository  = "github.com/${var.github_org}/${var.github_repo}"
    }
  }
}

# ─── S3 state bucket ───────────────────────────────────────────────────────
# Deterministic name: "aegis-enclave-tfstate-<env>-<account_id>" (ADR-0052,
# reconciling ADR-0025's original random_id naming to the break-glass-seeded
# live bucket). Deterministic beats random_id here: the name is reproducible
# from (env, account) alone, so a re-bootstrap or a forker lands the same
# bucket without first reading a prior terraform output.
data "aws_caller_identity" "current" {}

# tfsec PoC-scope (ADR-0003 calibration): the state bucket uses SSE-S3 (below)
# and full public-access-block; access logging + a customer-managed KMS key are
# production-hardening upgrades, not PoC scope.
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "tfstate" {
  bucket = "aegis-enclave-tfstate-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── DynamoDB lock table ───────────────────────────────────────────────────
# DynamoDB encrypts every table at rest by default (AWS-owned key) — the lock
# table holds only lock IDs, so an explicit SSE block + customer-managed KMS key
# is a production-hardening upgrade, not PoC scope (ADR-0003).
#tfsec:ignore:aws-dynamodb-enable-at-rest-encryption
#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "tflock" {
  name         = "aegis-enclave-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ─── GitHub Actions OIDC provider (SHARED — referenced, NOT managed) ────────
# token.actions.githubusercontent.com is a per-ACCOUNT singleton, created and
# owned by the aegis landing-zone (live tags: Project=landing-zone-lab), and
# shared by every repo's CI roles — the enclave apply role, the platform apply
# role, and any future federated role all trust this one provider.
#
# The enclave bootstrap must NOT manage it. Managing it here would (a) re-tag
# shared infra as enclave-owned, and (b) let an enclave `terraform destroy`
# DELETE the provider out from under every other repo's CI. So it is a
# data-source lookup, owned and lifecycle-managed by the landing-zone.
# (ADR-0052 reconcile — supersedes the ADR-0026 resource block that wrongly
# assumed enclave ownership; the live provider predates this composition.)
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ─── IAM role: GitHub Actions PR plan (read-only) — DE-INSTANTIATED ─────────
# The read-only PR-plan role (ADR-0026) was NEVER provisioned in the governed
# staging account: `.github/workflows/terraform-plan.yml` gates its cloud-plan
# job on `vars.AWS_TF_PLAN_ROLE_ARN != ''` (Phase-1 dormant default), and that
# repo variable is intentionally unset — PR-time lint/validate/fmt/tflint run
# without any AWS role, and the governed deploy path uses the apply role below.
#
# ADR-0052 reconciles this bootstrap composition to the live governed-staging
# state. The plan role + its ReadOnlyAccess attachment + the scoped state-access
# policy + attachment lived here but had no live counterpart, so a PlatformAdmin
# `terraform apply` would have tripped the org SCP on iam:CreateRole. They are
# removed so `plan`/`apply` are a clean no-op against live. The capability is NOT
# lost: the design is preserved in ADR-0026 + this file's git history, and the
# workflow gate re-opens the moment AWS_TF_PLAN_ROLE_ARN is set. To re-enable,
# re-add these resources and break-glass `apply` (iam:CreateRole is SCP-gated for
# the human path — by design).
