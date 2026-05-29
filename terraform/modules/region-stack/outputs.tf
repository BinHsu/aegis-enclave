# outputs.tf — values the root composition re-surfaces, plus the inputs the
# root needs to wire platform-layer resources (Route53 health checks read the
# ALB arn_suffix; DynamoDB replica config reads nothing region-specific).

# ─── Network ────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC identifier for this region."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs across 3 AZs."
  value       = module.vpc.private_subnets
}

output "vpc_endpoint_ids" {
  description = "Interface VPC endpoint identifiers (PrivateLink — ADR-0019)."
  value       = { for k, v in aws_vpc_endpoint.interfaces : k => v.id }
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway VPC endpoint identifier."
  value       = aws_vpc_endpoint.s3.id
}

output "dynamodb_gateway_endpoint_id" {
  description = "DynamoDB gateway VPC endpoint identifier (ADR-0042)."
  value       = aws_vpc_endpoint.dynamodb.id
}

# ─── ALB ────────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "Internal ALB DNS — reachable only from VPC (Client VPN)."
  value       = module.alb.dns_name
}

output "alb_zone_id" {
  description = "Internal ALB hosted zone ID — used by the root for Route53 alias records."
  value       = module.alb.zone_id
}

output "alb_cert_arn" {
  description = "ACM ARN of the ALB's self-signed TLS certificate (ADR-0027)."
  value       = aws_acm_certificate.alb.arn
}

output "alb_self_signed_ca_pem" {
  description = "Self-signed CA cert PEM for the internal ALB. Public material — not sensitive."
  value       = tls_self_signed_cert.alb.cert_pem
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix ('app/<name>/<id>') — the AWS/ApplicationELB 'LoadBalancer' dimension."
  value       = module.alb.arn_suffix
}

output "alb_target_group_arn_suffix" {
  description = "ALB target group ARN suffix ('targetgroup/<name>/<id>') — the AWS/ApplicationELB 'TargetGroup' dimension."
  value       = module.alb.target_groups["app"].arn_suffix
}

# ─── ECR ────────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "ECR repository URL for application images in this region."
  value       = module.ecr.repository_url
}

# ─── Client VPN ─────────────────────────────────────────────────────────────

output "client_vpn_endpoint_id" {
  description = "AWS Client VPN endpoint identifier."
  value       = aws_ec2_client_vpn_endpoint.main.id
}

# ─── ECS ────────────────────────────────────────────────────────────────────

output "ecs_cluster_arn" {
  description = "ECS Fargate cluster ARN."
  value       = module.ecs.cluster_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name (bare, not ARN) — the AWS/ECS 'ClusterName' dimension."
  value       = module.ecs.cluster_name
}

output "worker_service_arn" {
  description = "ARN of the ECS service running the SQS consumer worker."
  value       = aws_ecs_service.worker.id
}

output "worker_service_name" {
  description = "ECS worker service bare name — the AWS/ECS 'ServiceName' dimension."
  value       = aws_ecs_service.worker.name
}

output "bootstrap_task_arn" {
  description = "ARN of the ECS task definition for the cache-bootstrap one-shot."
  value       = aws_ecs_task_definition.cache_bootstrap.arn
}

# ─── SQS ────────────────────────────────────────────────────────────────────

output "sqs_primes_url" {
  description = "SQS queue URL for the primes job queue."
  value       = aws_sqs_queue.primes.url
}

output "sqs_primes_name" {
  description = "SQS primes queue bare name — the AWS/SQS 'QueueName' dimension."
  value       = aws_sqs_queue.primes.name
}

# ─── Valkey ─────────────────────────────────────────────────────────────────

output "valkey_endpoint" {
  description = "ElastiCache Serverless Valkey endpoint (host:port)."
  value       = "${aws_elasticache_serverless_cache.valkey.endpoint[0].address}:${aws_elasticache_serverless_cache.valkey.endpoint[0].port}"
  sensitive   = true
}

output "valkey_cache_name" {
  description = "ElastiCache Serverless cache name — the AWS/ElastiCache 'CacheName' dimension."
  value       = aws_elasticache_serverless_cache.valkey.name
}

# ─── Result store (ADR-0048) ────────────────────────────────────────────────

output "results_bucket_arn" {
  description = "ARN of the per-region result bucket — passed to the PEER region's module as `peer_results_bucket_arn` so the peer's CRR IAM policy can grant ReplicateObject on this bucket's keys."
  value       = aws_s3_bucket.results.arn
}

output "results_bucket_id" {
  description = "Name of the per-region result bucket (e.g. 'aegis-enclave-results-eu-central-1')."
  value       = aws_s3_bucket.results.id
}

output "s3_replication_role_arn" {
  description = "ARN of the IAM role that the root-level `aws_s3_bucket_replication_configuration` resource assumes to replicate this bucket's objects to the peer."
  value       = aws_iam_role.s3_replication.arn
}
