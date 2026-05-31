# variables.tf — inputs for one regional stack instance.
#
# Every per-region resource (VPC, ALB, ECS, SQS, Valkey, Client VPN, CloudWatch
# alarms, ...) lives in this module. The root composition (terraform/main.tf)
# instantiates this module once per region in var.regions, passing the correct
# regional `aws` provider per call.
#
# Inputs fall into three groups:
#   1. region identity      — `region`, `vpc_cidr`, the VPN cert ARNs
#   2. shared workload knobs — image tag, worker counts, valkey/sqs tunables
#   3. cross-region wiring   — the DynamoDB table name/arn from the platform
#                              layer (DynamoDB Global Tables: one logical table
#                              shared by every region).

# ─── Region identity ────────────────────────────────────────────────────────

variable "region" {
  description = "AWS region this stack instance deploys into. Must match the region of the `aws` provider passed in by the root module call."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.region))
    error_message = "region must be a valid AWS region pattern (e.g. eu-central-1)."
  }
}

variable "name_prefix" {
  description = "Resource name prefix. Root passes 'aegis-enclave' for the platform region and a region-suffixed prefix for peers, keeping global resource names (ECS clusters, SQS queues, IAM roles) unique across regions in the same account."
  type        = string
  default     = "aegis-enclave"
}

variable "vpc_cidr" {
  description = "Static VPC CIDR for this region (mutually exclusive with ipv4_ipam_pool_id; null when allocating from IPAM). Peers must not overlap each other (no inter-region CIDR collision if later peered via Transit Gateway)."
  type        = string
  default     = null
}

variable "ipv4_ipam_pool_id" {
  description = "IPAM pool ID to allocate the VPC CIDR from (ADR-0050). Null = use the static vpc_cidr. When set, the VPC allocates from IPAM (one tracked allocation) and the effective CIDR is previewed at plan time for the subnet / SG / VPN derivations."
  type        = string
  default     = null
}

variable "ipv4_netmask_length" {
  description = "Netmask length to request from the IPAM pool (ADR-0050; only consulted when ipv4_ipam_pool_id is set). Default /16 matches the legacy static-CIDR size, so the three /24 private-subnet derivation is unchanged."
  type        = number
  default     = 16
}

variable "vpn_client_cidr" {
  description = "Client VPN client address pool for this region. Must not overlap any region's VPC CIDR or any other region's VPN client CIDR."
  type        = string
  default     = "10.20.0.0/16"
}

variable "server_cert_arn" {
  description = "ACM certificate ARN for the Client VPN endpoint server cert in this region."
  type        = string
}

variable "client_cert_arn" {
  description = "ACM certificate ARN for the Client VPN root CA (mutual-TLS) in this region."
  type        = string
}

variable "alb_internal_hostname" {
  description = "Hostname embedded in the internal ALB's self-signed cert (ADR-0027). Region-agnostic: the operator's curl uses --resolve <this>:443:<alb-private-ip>."
  type        = string
  default     = "api.enclave.internal"
}

# ─── Data layer wiring (DynamoDB Global Tables — platform-owned) ─────────────

variable "dynamodb_table_name" {
  description = "DynamoDB executions table name. The table itself is a platform-layer resource (root main.tf); each region's app/worker reach it via the regional DynamoDB gateway endpoint."
  type        = string
}

variable "dynamodb_table_arn" {
  description = "DynamoDB executions table ARN (home-region ARN). Used to scope this region's IAM policies; the module also derives the region-local replica ARN form internally."
  type        = string
}

variable "account_id" {
  description = "AWS account ID — used to construct the region-local DynamoDB replica ARN for IAM scoping."
  type        = string
}

# ─── Container image ────────────────────────────────────────────────────────

variable "image_tag" {
  description = "Container image tag (git short SHA in production paths). Pushed to this region's ECR repo by cloud-up.sh."
  type        = string
  default     = "latest"
}

# ─── Worker + autoscaling ───────────────────────────────────────────────────

variable "worker_min_count" {
  description = "Minimum worker ECS task count (one per AZ in the 3-AZ posture)."
  type        = number
  default     = 3
}

variable "worker_max_count" {
  description = "Maximum worker ECS task count (autoscaling ceiling)."
  type        = number
  default     = 9
}

variable "app_desired_count" {
  description = "Desired app ECS task count (one per AZ in the 3-AZ posture)."
  type        = number
  default     = 3
}

variable "backpressure_threshold_factor" {
  description = "SQS-depth target-tracking scaling target value."
  type        = number
  default     = 5
}

variable "sqs_visibility_timeout" {
  description = "SQS message visibility timeout in seconds (1.5x compute budget)."
  type        = number
  default     = 90
}

# ─── Valkey tunables ────────────────────────────────────────────────────────

variable "valkey_max_storage_gb" {
  description = "ElastiCache Serverless Valkey maximum data storage in GB."
  type        = number
  default     = 1
}

# ─── Result store (ADR-0048) ────────────────────────────────────────────────

variable "result_bucket_prefix" {
  description = "Prefix for the per-region result bucket name. Final name is '<prefix>-<region>'. See ADR-0048 § 2."
  type        = string
  default     = "aegis-enclave-results"
}

variable "valkey_max_ecpu_per_sec" {
  description = "ElastiCache Serverless Valkey maximum eCPU per second."
  type        = number
  default     = 5000
}

# ─── Alerting ───────────────────────────────────────────────────────────────

variable "alarm_email" {
  description = "Email for SLO alarm notifications via SNS. Empty disables email delivery (alarms still fire and are visible in CloudWatch). Per-region SNS topic is created only when this is set."
  type        = string
  default     = ""

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alarm_email))
    error_message = "alarm_email must be empty or a valid email address."
  }
}
