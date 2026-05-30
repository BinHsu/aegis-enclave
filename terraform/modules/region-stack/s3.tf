###############################################################################
# Result store — S3 bucket + IAM + Gateway Endpoint (ADR-0048)
###############################################################################
#
# Per ADR-0048 the gzipped primes-list payload lives in S3 (not in the DDB
# row, which would breach the 400 KB item cap for end=10^7). Each region
# owns its own independent bucket; there is no cross-region replication
# (ADR-0049 replaced bidirectional CRR with recompute-on-miss — a cross-
# region read regenerates the object locally from the DDB-replicated range).
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

# Versioning is retained for the lifecycle policy's clean
# `noncurrent_version_expiration` knob. (It was originally mandatory for the
# bidirectional CRR removed by ADR-0049; the lifecycle use is why it stays.)
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


# ─── Cross-region replication: removed (ADR-0049) ───────────────────────────
# The bidirectional CRR IAM role + policy that lived here were removed per
# ADR-0049. Each region's bucket is now independent (no replication source or
# destination); cross-region result availability is provided by recompute-on-
# miss in the GET handler, not by replicating objects. No replication role is
# needed. Bucket versioning above is retained for the lifecycle policy's
# noncurrent-version expiration, not for CRR.


# ─── S3 Gateway Endpoint ─────────────────────────────────────────────────────
# Already defined in network.tf as `aws_vpc_endpoint.s3` — kept there because
# it pre-existed ADR-0048 for module-image-pull paths. The same endpoint
# serves the result-bucket reads/writes from ECS tasks (ADR-0019: private
# VPC; no IGW / NAT — every S3 hop goes through this endpoint).
