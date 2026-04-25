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
