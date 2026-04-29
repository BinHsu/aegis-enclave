# terraform/bootstrap/main.tf — One-time provisioning of the deployment prerequisites.
#
# What lives here:
#   1. S3 bucket  + DynamoDB lock table  → state backend for `terraform/main.tf`
#                                          (ADR-0025)
#   2. GitHub Actions OIDC provider + read-only IAM role
#                                        → `terraform plan` on PR (ADR-0026)
#
# How to use (one-time, run from this directory):
#   terraform init              # uses LOCAL backend — bootstrap holds its own state
#   terraform apply
#   terraform output            # capture bucket name + lock table + role ARN
#
# Then:
#   - Paste `tfstate_bucket` + `tflock_table` into `terraform/main.tf`'s
#     `backend "s3"` block (currently committed-out — uncomment after bootstrap).
#   - Set the `gha_terraform_plan_role_arn` GitHub repository VARIABLE so the
#     `.github/workflows/terraform-plan.yml` workflow can assume it on PR.
#
# This module is intentionally separate from the main composition. The main
# composition's state backend cannot reference the bucket holding its own
# state — chicken-and-egg. See ADR-0025 § "Why a separate bootstrap module".

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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
resource "random_id" "tfstate_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "aegis-enclave-tfstate-${random_id.tfstate_suffix.hex}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

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

# ─── GitHub Actions OIDC provider ──────────────────────────────────────────
# Allows GitHub Actions workflows to assume an AWS role via short-lived
# tokens, no long-lived access keys. See ADR-0026.
#
# The thumbprint below is GitHub's intermediate CA (DigiCert). AWS used to
# require this; recent AWS docs say the thumbprint is informational only —
# AWS validates the token against the OIDC provider's JWKS endpoint. We
# include a known-good value for backwards-compat and to avoid drift on
# `terraform plan`.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ─── IAM role: GitHub Actions PR plan (read-only) ──────────────────────────
data "aws_iam_policy_document" "gha_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Restrict to this repo only — without this, ANY GitHub repo could
    # assume the role. The `sub` claim binds the trust to a specific
    # repository, optionally to specific branches / events.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Allow PR events (read-only plan) and main-branch pushes (also read-only
      # since this role doesn't grant apply). Tighten further if needed.
      values = [
        "repo:${var.github_org}/${var.github_repo}:pull_request",
        "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "gha_terraform_plan" {
  name               = "aegis-enclave-gha-terraform-plan"
  assume_role_policy = data.aws_iam_policy_document.gha_trust.json
  description        = "GitHub Actions OIDC — read-only terraform plan on PR (ADR-0026)"
}

# ReadOnlyAccess covers the Describe/Get/List actions every Terraform plan
# needs to refresh state (across EC2, ECS, DynamoDB, ALB, ECR, IAM, etc.).
resource "aws_iam_role_policy_attachment" "gha_readonly" {
  role       = aws_iam_role.gha_terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Plan acquires the state lock (DynamoDB) and may write a refreshed state
# back to S3 on drift. Both writes are tightly scoped to the state bucket
# + lock table only — outside those, the role is strictly read-only.
data "aws_iam_policy_document" "gha_state_access" {
  statement {
    sid    = "StateBucketReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
  }

  statement {
    sid    = "LockTableReadWrite"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = [aws_dynamodb_table.tflock.arn]
  }
}

resource "aws_iam_policy" "gha_state_access" {
  name        = "aegis-enclave-gha-state-access"
  description = "Tightly-scoped state bucket + lock table access for PR plan job"
  policy      = data.aws_iam_policy_document.gha_state_access.json
}

resource "aws_iam_role_policy_attachment" "gha_state_access" {
  role       = aws_iam_role.gha_terraform_plan.name
  policy_arn = aws_iam_policy.gha_state_access.arn
}
