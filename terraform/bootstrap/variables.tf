# bootstrap/variables.tf — inputs for the deployment prerequisite module.

variable "region" {
  description = "AWS region — single-region eu-central-1 per ADR-0007"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Deploy environment segment in the state bucket name: aegis-enclave-tfstate-<environment>-<account_id> (ADR-0052)"
  type        = string
  default     = "staging"
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
  description = "GitHub repository name. Retained for the de-instantiated read-only plan role's OIDC trust scope (ADR-0026/0052) and for documentation; the live apply role binds by immutable github_repo_id, not by name."
  type        = string
  default     = "aegis-enclave"
}

variable "github_repo_id" {
  description = "Immutable GitHub repository ID (numeric, as a string) for the APPLY role's rename-proof OIDC trust (ADR-0051). Find it with: gh api repos/<org>/<repo> --jq .id"
  type        = string
  default     = "1220640710" # BinHsu/aegis-enclave
}
