# variables.tf — inputs consumed by main.tf
#
# Defaults are case-study-shaped: single region, single environment tag,
# placeholder cost-center / owner. Forkers override per workspace.
#
# Implements the ADR-0042 greenfield DynamoDB Global Tables target:
# secondary-region + DynamoDB variables are first-class; no relational-DB
# variables remain.

variable "region" {
  description = "Primary AWS region; ADR-0042 greenfield primary, default Frankfurt"
  type        = string
  default     = "eu-central-1"
}

variable "secondary_region" {
  description = "Secondary region for DDB Global Tables active-active replica + multi-region infra. Empty = single-region scope."
  type        = string
  default     = ""
  validation {
    condition     = var.secondary_region == "" || can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.secondary_region))
    error_message = "secondary_region must be empty or a valid AWS region pattern (e.g. eu-west-1)."
  }
}

variable "environment" {
  description = "Deployment environment tag (case-study | dev | prod)"
  type        = string
  default     = "case-study"
}

variable "cost_center" {
  description = "FinOps cost-center tag for chargeback / showback"
  type        = string
  default     = "engineering"
}

variable "owner" {
  description = "Resource owner tag"
  type        = string
  default     = "bin.hsu"
}

variable "vpc_cidr" {
  description = "VPC CIDR for aegis-enclave (primary region)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "secondary_vpc_cidr" {
  description = "VPC CIDR for secondary region (avoid overlap with primary 10.0.0.0/16)"
  type        = string
  default     = "10.10.0.0/16"
}

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

variable "server_cert_arn" {
  description = "ACM certificate ARN for Client VPN endpoint server cert (primary region)"
  type        = string
  default     = "" # Operator fills in via separate ACM provisioning step (scripts/bootstrap-vpn-certs.sh)
}

variable "client_cert_arn" {
  description = "ACM certificate ARN for the Client VPN root CA - mutual-TLS authentication (primary region)"
  type        = string
  default     = ""
}

variable "secondary_server_cert_arn" {
  description = "ACM certificate ARN for Client VPN endpoint server cert in secondary region. Required when secondary_region != ''."
  type        = string
  default     = ""
}

variable "secondary_client_cert_arn" {
  description = "ACM certificate ARN for the Client VPN root CA in secondary region. Required when secondary_region != ''."
  type        = string
  default     = ""
}

variable "alb_internal_hostname" {
  description = "Hostname embedded in the internal ALB's self-signed cert (ADR-0027). Operator's curl uses --resolve <this>:443:<alb-private-ip> against it."
  type        = string
  default     = "api.enclave.internal"
}

# ─── Async worker + distributed cache (ADR-0029 + ADR-0031) ─────────────────

variable "image_tag" {
  description = "Container image tag (typically git short SHA, e.g. 'abc12345' or 'abc12345-dirty-7e33ff10' for uncommitted changes). Written by scripts/cloud-up.sh into image-tag.auto.tfvars. Default 'latest' is for backwards-compat; production paths should always pass an explicit tag for IMMUTABLE ECR + audit trail."
  type        = string
  default     = "latest"
}

variable "worker_min_count" {
  description = "Minimum number of worker ECS tasks (SQS consumer). Default 3 = one per AZ in the 3-AZ posture (ADR-0007 reconsidered 04/28). Loss of one AZ leaves 2/3 capacity."
  type        = number
  default     = 3
}

variable "worker_max_count" {
  description = "Maximum number of worker ECS tasks (autoscaling ceiling). Default 9 keeps the 3x scale headroom over min_count."
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
  description = "AWS CLI profile name for operator-side scripts (cloud-up / cloud-down / cloud-evidence / cloud-smoke). NOT used by Terraform itself — provider auth comes from the env at apply time. Operator-only metadata; safe to leave empty for forkers in env-based auth."
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "Email address for SLO alarm notifications via SNS. Empty string (default) disables email delivery; alarms still fire and are visible in CloudWatch Console + EventBridge audit trail (per ADR-0041 — alerting is opt-in to avoid forker getting unsolicited mail). Set via `tfvars-init.sh` prompt or `TF_ALARM_EMAIL` env var. Subscriber must click the AWS confirmation email after first apply before notifications deliver."
  type        = string
  default     = ""
  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alarm_email))
    error_message = "alarm_email must be empty or a valid email address."
  }
}

variable "backpressure_threshold_factor" {
  description = "Backpressure = factor × worker_count. Matches BACKPRESSURE_FACTOR env var default."
  type        = number
  default     = 5
}

variable "sqs_visibility_timeout" {
  description = "SQS message visibility timeout in seconds (1.5 × compute_budget_seconds = 90)."
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
  description = "Monthly AWS cost budget ceiling in USD (see budget.tf, ADR-0043). Forker-tunable starting point, not a prescriptive cap - set this to your own steady-state estimate. Default 25 suits the case-study's ~3h apply-then-destroy window; raise it for a long-running fork. AWS Budgets itself is free."
  type        = number
  default     = 25
}

variable "budget_notification_email" {
  description = "Email for AWS Budgets alert notifications (80%-actual + 100%-forecasted). Empty (default) leaves the budget a silent cost tracker - set it to arm alerts. Mirrors the alarm_email opt-in pattern so forkers get no unsolicited mail. Operator/forker-supplied; never commit a real address (CLAUDE.md section 5)."
  type        = string
  default     = ""
  validation {
    condition     = var.budget_notification_email == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.budget_notification_email))
    error_message = "budget_notification_email must be empty or a valid email address."
  }
}
