# variables.tf — inputs consumed by main.tf
#
# Defaults are case-study-shaped: single region, single environment tag,
# placeholder cost-center / owner. Phase 1 build can override per workspace.

variable "region" {
  description = "AWS region — single-region eu-central-1 per ADR-0007"
  type        = string
  default     = "eu-central-1"
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
  description = "VPC CIDR for aegis-enclave"
  type        = string
  default     = "10.0.0.0/16"
}

variable "server_cert_arn" {
  description = "ACM certificate ARN for Client VPN endpoint server cert"
  type        = string
  default     = "" # Phase 1 fills in via separate ACM provisioning step
}

variable "client_cert_arn" {
  description = "ACM certificate ARN for the Client VPN root CA (mutual-TLS authentication)"
  type        = string
  default     = ""
}

variable "alb_internal_hostname" {
  description = "Hostname embedded in the internal ALB's self-signed cert (ADR-0027). Operator's curl uses --resolve <this>:443:<alb-private-ip> against it."
  type        = string
  default     = "api.enclave.internal"
}

# ─── Phase 2.3/2.4 — Async worker + distributed cache ────────────────────────

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

variable "compute_budget_seconds" {
  description = "Worker SIGALRM compute budget in seconds. Must match prime_service.primes._SIGALRM_SECONDS."
  type        = number
  default     = 60
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
