# bootstrap/variables.tf — inputs for the Phase-2 prerequisite module.

variable "region" {
  description = "AWS region — single-region eu-central-1 per ADR-0007"
  type        = string
  default     = "eu-central-1"
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

variable "github_org" {
  description = "GitHub org / user owning the repository (for OIDC trust scope)"
  type        = string
  default     = "BinHsu"
}

variable "github_repo" {
  description = "GitHub repository name (for OIDC trust scope)"
  type        = string
  default     = "aegis-enclave"
}
