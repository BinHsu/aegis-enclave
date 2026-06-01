# bootstrap/outputs.tf — values to wire into terraform/main.tf and GitHub Actions.

output "tfstate_bucket" {
  description = "S3 bucket name to paste into terraform/main.tf's `backend \"s3\"` block (bucket = ...)"
  value       = aws_s3_bucket.tfstate.id
}

output "tflock_table" {
  description = "DynamoDB table name for the state lock (dynamodb_table = ...)"
  value       = aws_dynamodb_table.tflock.name
}

# NOTE: gha_terraform_plan_role_arn output removed in ADR-0052 — the read-only
# PR-plan role is de-instantiated in the governed-staging reconcile (see main.tf).
# Re-add it alongside the role if/when AWS_TF_PLAN_ROLE_ARN is wired.

output "gha_terraform_apply_role_arn" {
  description = "Set this as a GitHub repository VARIABLE named AWS_TF_APPLY_ROLE_ARN so .github/workflows/cloud-apply.yml + cloud-destroy.yml can assume it (ADR-0051). gh-tf-apply-enclave is the SCP-carved-out apply identity for the governed-org path."
  value       = aws_iam_role.gha_terraform_apply.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN (informational; SHARED landing-zone-owned singleton, looked up via data source — ADR-0052)"
  value       = data.aws_iam_openid_connect_provider.github.arn
}
