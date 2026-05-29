###############################################################################
# Result store — S3 bucket + IAM + Gateway Endpoint (ADR-0048)
###############################################################################
#
# Per ADR-0048 the gzipped primes-list payload lives in S3 (not in the DDB
# row, which would breach the 400 KB item cap for end=10^7). Each region
# owns its own bucket; bidirectional CRR between regions is configured at
# the root module to avoid a per-module dependency cycle (see main.tf).
#
# Naming: "${result_bucket_prefix}-${region}" — bucket name carries the
# region so `s3_store.py` can resolve it at runtime from AWS_REGION alone.
# The DDB row stores only `s3_key` (bucket-relative), never the bucket
# name or full URI (ADR-0048 § 3 keystone for local-replica reads).
#
# Private-VPC posture (ADR-0019) is preserved by the S3 Gateway Endpoint
# below — S3 traffic from ECS tasks routes via the endpoint, never via
# an IGW or NAT (neither of which this VPC has).


# ─── Bucket + hardening (versioning, SSE, lifecycle, public-access block) ───

# description: bucket-name format is "prefix-region"; e.g. "aegis-enclave-results-eu-central-1"
# tfsec PoC-scope decision: server access logging is intentionally NOT
# enabled (cost + complexity beyond Tier-2 scope; CloudTrail data events
# are the production-direction upgrade path — see ADR-0048 § Negative).
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "results" {
  bucket = "${var.result_bucket_prefix}-${var.region}"

  tags = {
    Name      = "${var.name_prefix}-results"
    Component = "result-store"
    Region    = var.region
  }
}

# Versioning is mandatory for CRR (both source and destination must have
# versioning enabled). It also gives the lifecycle policy a clean
# `noncurrent_version_expiration` knob.
resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 by default. Matches ADR-0042's posture on DynamoDB (no KMS key
# management overhead at PoC scope). KMS can be promoted later if a
# BSI-C5 / production-grade encryption story is required.
# tfsec PoC-scope decision: customer-managed KMS keys add per-key cost +
# key-rotation operations that are out of scope; SSE-S3 is the AWS default
# and consistent with the rest of the stack.
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Lifecycle: align with the DDB TTL policy (done = 30 d, failed = 90 d).
# The S3 key layout in `s3_store.key_for()` is "done/{execution_id}.json.gz"
# so the 30-day expiration on the `done/` prefix matches the DDB done TTL.
# If/when worker writes failed payloads to S3 under "failed/", add a
# second rule with 90-day expiration.
resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "expire-done-after-30d"
    status = "Enabled"
    filter {
      prefix = "done/"
    }
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Hard-block any public access — the bucket holds compute results, never
# served externally; clients reach it only via the in-VPC GET handler.
resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# ─── Replication IAM role (consumed by the root-level CRR config) ───────────

# Note: the actual `aws_s3_bucket_replication_configuration` resources live
# in the ROOT module (`terraform/main.tf`) — putting them here would create
# a module-level dependency cycle (each module would need the other's
# bucket ARN as an input). The role we create here is what the root-level
# CRR config will reference via the `s3_replication_role_arn` output.
resource "aws_iam_role" "s3_replication" {
  name = "${var.name_prefix}-s3-replication"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "s3.amazonaws.com" }
    }]
  })

  tags = {
    Component = "s3-replication"
  }
}

# The policy is split: read-side on the local bucket, replicate-side on
# the peer bucket. `peer_results_bucket_arn` is null in single-region
# applies; we gate the statement so the policy is still valid.
# tfsec false positive: '<bucket>/*' is the canonical scope for "all
# versioned objects in this bucket" required by S3 CRR. AWS's own CRR
# IAM examples use the exact same pattern.
#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_role_policy" "s3_replication" {
  role = aws_iam_role.s3_replication.id
  name = "s3-replication"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "s3:GetReplicationConfiguration",
            "s3:ListBucket",
          ]
          Resource = aws_s3_bucket.results.arn
        },
        {
          Effect = "Allow"
          Action = [
            "s3:GetObjectVersionForReplication",
            "s3:GetObjectVersionAcl",
            "s3:GetObjectVersionTagging",
          ]
          Resource = "${aws_s3_bucket.results.arn}/*"
        },
      ],
      var.peer_results_bucket_arn != null ? [{
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
        ]
        Resource = "${var.peer_results_bucket_arn}/*"
      }] : [],
    )
  })
}


# ─── S3 Gateway Endpoint ─────────────────────────────────────────────────────
# Already defined in network.tf as `aws_vpc_endpoint.s3` — kept there because
# it pre-existed ADR-0048 for module-image-pull paths. The same endpoint
# serves the result-bucket reads/writes from ECS tasks (ADR-0019: private
# VPC; no IGW / NAT — every S3 hop goes through this endpoint).
