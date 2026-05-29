# variables.tf — root-composition inputs.
#
# Two layers (ADR-0042 greenfield DynamoDB Global Tables target):
#   - Platform layer  — single Terraform config / single apply / single state.
#     The DynamoDB Global Table, Route53, and the AWS Budget live here.
#   - Regional layer  — one `region-stack` module instance per region.
#
# The old flat per-region vars (region / secondary_region / vpc_cidr /
# secondary_* / *_cert_arn) are replaced by `platform_region` + the `regions`
# map: every region (including the platform region) is a peer entry in the map
# and runs an identical regional stack. Single-region scope = a one-entry map.

# ─── Region topology ────────────────────────────────────────────────────────

variable "platform_region" {
  description = "Home region: the default `aws` provider, and where the platform-layer resources (DynamoDB table resource, Route53, AWS Budget) are created. Must also be a key in `var.regions`."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.platform_region))
    error_message = "platform_region must be a valid AWS region pattern (e.g. eu-central-1)."
  }
}

variable "regions" {
  description = <<-EOT
    Per-region deployment map, keyed by AWS region name. Every entry runs one
    `region-stack` module instance. The `platform_region` MUST be a key here.

    Single-region scope = a one-entry map. Multi-region active-active = two
    entries (the DynamoDB replica + Route53 weighted records switch on
    automatically once a second region is present).

    Each value carries the per-region scalars:
      - vpc_cidr        : region VPC CIDR (peers must not overlap)
      - vpn_client_cidr : Client VPN client pool (must not overlap any VPC or
                          any other region's VPN pool)
      - server_cert_arn : ACM ARN for the Client VPN server cert in that region
      - client_cert_arn : ACM ARN for the Client VPN root CA in that region

    Terraform cannot pass a per-instance provider to a for_each module, so the
    root instantiates `region-stack` with explicit module calls — currently
    one platform-region call + one count-gated peer call. Adding a THIRD region
    requires adding a third explicit module call + provider alias in main.tf.
  EOT
  type = map(object({
    vpc_cidr        = string
    vpn_client_cidr = optional(string, "10.20.0.0/16")
    server_cert_arn = string
    client_cert_arn = string
  }))

  validation {
    condition     = length(var.regions) >= 1 && length(var.regions) <= 2
    error_message = "regions must hold 1 or 2 entries — the root wires explicit module calls for the platform region plus one optional peer. A third region needs a code change in main.tf (see the variable description)."
  }

  validation {
    condition     = contains(keys(var.regions), var.platform_region)
    error_message = "platform_region must be one of the keys in the regions map."
  }

  validation {
    condition     = alltrue([for r in keys(var.regions) : can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", r))])
    error_message = "every regions key must be a valid AWS region pattern (e.g. eu-central-1)."
  }
}

variable "alb_internal_hostname" {
  description = "Hostname embedded in every region's internal ALB self-signed cert (ADR-0027). Region-agnostic — one global value. The operator's curl uses --resolve <this>:443:<alb-private-ip>."
  type        = string
  default     = "api.enclave.internal"
}

# ─── Tags ───────────────────────────────────────────────────────────────────

variable "environment" {
  description = "Deployment environment tag (case-study | dev | prod)."
  type        = string
  default     = "case-study"
}

variable "cost_center" {
  description = "FinOps cost-center tag for chargeback / showback."
  type        = string
  default     = "engineering"
}

variable "owner" {
  description = "Resource owner tag."
  type        = string
  default     = "bin.hsu"
}

# ─── Data layer — DynamoDB (ADR-0042) ───────────────────────────────────────

variable "dynamodb_table_name" {
  description = "DynamoDB table name for executions (ADR-0042). Used by app/worker via DYNAMODB_TABLE_NAME env var."
  type        = string
  default     = "aegis-enclave-executions"
}

variable "route53_zone_name" {
  description = "Existing Route53 hosted zone name (e.g. enclave.example.com). Forker provides; multi-region scope uses it for weighted A records. Empty = no Route53 wiring."
  type        = string
  default     = ""
}

# ─── Container image ────────────────────────────────────────────────────────

variable "image_tag" {
  description = "Container image tag (typically git short SHA). Written by scripts/cloud-up.sh into image-tag.auto.tfvars. Production paths should always pass an explicit tag for IMMUTABLE ECR + audit trail."
  type        = string
  default     = "latest"
}

# ─── Async worker + distributed cache (ADR-0029 + ADR-0031) ─────────────────

variable "worker_min_count" {
  description = "Minimum number of worker ECS tasks (SQS consumer). Default 3 = one per AZ in the 3-AZ posture."
  type        = number
  default     = 3
}

variable "worker_max_count" {
  description = "Maximum number of worker ECS tasks (autoscaling ceiling)."
  type        = number
  default     = 9
}

# Intent anchor: consumed as documentation by sqs_visibility_timeout's 1.5x
# derivation, deliberately not referenced by HCL.
# tflint-ignore: terraform_unused_declarations
variable "compute_budget_seconds" {
  description = "Worker SIGALRM compute budget in seconds. Must match prime_service.primes._SIGALRM_SECONDS."
  type        = number
  default     = 60
}

# Operator-script metadata: lives in the tfvars file for cloud-*.sh,
# deliberately not consumed by HCL.
# tflint-ignore: terraform_unused_declarations
variable "aws_profile" {
  description = "AWS CLI profile name for operator-side scripts. NOT used by Terraform itself — provider auth comes from the env at apply time."
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "Email address for SLO alarm notifications via SNS. Empty (default) disables email delivery; alarms still fire and are visible in CloudWatch + EventBridge (ADR-0041 — opt-in)."
  type        = string
  default     = ""

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alarm_email))
    error_message = "alarm_email must be empty or a valid email address."
  }
}

variable "backpressure_threshold_factor" {
  description = "Backpressure = factor x worker_count. Matches BACKPRESSURE_FACTOR env var default."
  type        = number
  default     = 5
}

variable "sqs_visibility_timeout" {
  description = "SQS message visibility timeout in seconds (1.5 x compute_budget_seconds = 90)."
  type        = number
  default     = 90
}

variable "valkey_max_storage_gb" {
  description = "ElastiCache Serverless Valkey maximum data storage in GB. Caps cost within the 3h acceptance window."
  type        = number
  default     = 1
}

variable "valkey_max_ecpu_per_sec" {
  description = "ElastiCache Serverless Valkey maximum eCPU per second. Caps cost within the 3h acceptance window."
  type        = number
  default     = 5000
}

# ─── Cost guardrail (AWS Budgets — see budget.tf) ───────────────────────────

variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget ceiling in USD (see budget.tf, ADR-0043). Forker-tunable starting point. Default 25 suits the ~3h apply-then-destroy window; raise it for a long-running fork. AWS Budgets itself is free."
  type        = number
  default     = 25
}

variable "budget_notification_email" {
  description = "Email for AWS Budgets alert notifications (80%-actual + 100%-forecasted). Empty (default) leaves the budget a silent cost tracker. Never commit a real address (CLAUDE.md section 5)."
  type        = string
  default     = ""

  validation {
    condition     = var.budget_notification_email == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.budget_notification_email))
    error_message = "budget_notification_email must be empty or a valid email address."
  }
}

# ─── Result store (ADR-0048) ────────────────────────────────────────────────

variable "result_bucket_prefix" {
  description = "Prefix for the per-region S3 result bucket name (ADR-0048). Final bucket is '<prefix>-<region>' (e.g. 'aegis-enclave-results-eu-central-1'). The region is appended at module-eval time, and `s3_store.py` reconstructs the same name at runtime via AWS_REGION — so the DDB row carries only the bucket-relative s3_key and each region reads its local CRR replica."
  type        = string
  default     = "aegis-enclave-results"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.result_bucket_prefix)) && length(var.result_bucket_prefix) >= 3 && length(var.result_bucket_prefix) <= 50
    error_message = "result_bucket_prefix must be a DNS-compliant S3 bucket-name prefix (3-50 chars, lowercase + digits + hyphens, must start and end with alphanumeric)."
  }
}
