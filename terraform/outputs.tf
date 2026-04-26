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

output "alb_cert_arn" {
  description = "ACM ARN of the internal ALB's self-signed TLS certificate (ADR-0027)"
  value       = aws_acm_certificate.alb.arn
}

output "alb_self_signed_ca_pem" {
  description = "Self-signed CA cert PEM for the internal ALB. Save to a file and pass via `curl --cacert <file>` so the operator avoids `-k` and the cert chain is explicit. Public material — not sensitive."
  value       = tls_self_signed_cert.alb.cert_pem
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

# ─── Phase 2.3/2.4 — Async worker + distributed cache ────────────────────────

output "valkey_endpoint" {
  description = "ElastiCache Serverless Valkey endpoint (host:port) for the worker and app containers."
  value       = "${aws_elasticache_serverless_cache.valkey.endpoint[0].address}:${aws_elasticache_serverless_cache.valkey.endpoint[0].port}"
  sensitive   = true
}

output "sqs_primes_url" {
  description = "SQS queue URL for the aegis-enclave-primes job queue."
  value       = aws_sqs_queue.primes.url
}

output "worker_service_arn" {
  description = "ARN of the ECS service running the SQS consumer worker."
  value       = aws_ecs_service.worker.id
}

output "bootstrap_task_arn" {
  description = "ARN of the ECS task definition for the cache bootstrap one-shot task."
  value       = aws_ecs_task_definition.cache_bootstrap.arn
}
