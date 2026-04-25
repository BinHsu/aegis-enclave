# outputs.tf — surfaced values from the composition
#
# Each output corresponds to a wired-up module in main.tf. Sensitive values
# (RDS endpoint, master-user secret ARN) are flagged so plan output redacts them.

output "vpc_id" {
  description = "VPC identifier"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs across two AZs"
  value       = module.vpc.private_subnets
}

output "rds_endpoint" {
  description = "RDS PostgreSQL writer endpoint (Multi-AZ; private)"
  value       = module.rds.db_instance_endpoint
  sensitive   = true
}

output "rds_master_user_secret_arn" {
  description = "Secrets Manager ARN of the RDS master-user credentials"
  value       = module.rds.db_instance_master_user_secret_arn
  sensitive   = true
}

output "alb_dns_name" {
  description = "Internal ALB DNS — reachable only from VPC (Client VPN)"
  value       = module.alb.dns_name
}

output "ecr_repository_url" {
  description = "ECR repository URL for application images"
  value       = module.ecr.repository_url
}

output "client_vpn_endpoint_id" {
  description = "AWS Client VPN endpoint identifier"
  value       = aws_ec2_client_vpn_endpoint.main.id
}

output "ecs_cluster_arn" {
  description = "ECS Fargate cluster ARN"
  value       = module.ecs.cluster_arn
}

output "vpc_endpoint_ids" {
  description = "VPC interface endpoint identifiers (PrivateLink — see ADR-0019)"
  value       = { for k, v in aws_vpc_endpoint.interfaces : k => v.id }
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway VPC endpoint identifier"
  value       = aws_vpc_endpoint.s3.id
}
