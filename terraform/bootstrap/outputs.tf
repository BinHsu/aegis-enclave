# bootstrap/outputs.tf — values to wire into terraform/main.tf and GitHub Actions.

output "tfstate_bucket" {
  description = "S3 bucket name to paste into terraform/main.tf's `backend \"s3\"` block (bucket = ...)"
  value       = aws_s3_bucket.tfstate.id
}

output "tflock_table" {
  description = "DynamoDB table name for the state lock (dynamodb_table = ...)"
  value       = aws_dynamodb_table.tflock.name
}

output "gha_terraform_plan_role_arn" {
  description = "Set this as a GitHub repository VARIABLE named AWS_TF_PLAN_ROLE_ARN so the .github/workflows/terraform-plan.yml job can assume it"
  value       = aws_iam_role.gha_terraform_plan.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN (informational; reused by any other role you add later)"
  value       = aws_iam_openid_connect_provider.github.arn
}
