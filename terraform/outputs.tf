# outputs.tf — surfaced values from the composition.
#
# Output NAMES are preserved across the region-stack refactor — downstream
# operator scripts (cloud-evidence.sh, cloud-smoke.sh, ...) read them by name.
# Per-region values are re-sourced from module.region_platform (the home
# region) and module.region_peer[0] (the peer region, null when single-region).
#
# "Primary"/"secondary" naming in the output identifiers is retained for
# script compatibility; internally the platform/peer vocabulary is used.

# ─── Network (platform region) ──────────────────────────────────────────────

output "vpc_id" {
  description = "Platform-region VPC identifier"
  value       = module.region_platform.vpc_id
}

output "private_subnet_ids" {
  description = "Platform-region VPC private subnet IDs across 3 AZs"
  value       = module.region_platform.private_subnet_ids
}

# ─── DynamoDB executions table ────────────────────────────────────────────

output "dynamodb_table_name" {
  description = "DynamoDB executions table name (ADR-0042). App + worker reach it via DYNAMODB_TABLE_NAME env var."
  value       = aws_dynamodb_table.executions.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB executions table ARN (platform region)."
  value       = aws_dynamodb_table.executions.arn
}

output "dynamodb_stream_arn" {
  description = "DynamoDB stream ARN — V2 hook for archival to S3 / event-driven downstream consumers (NEW_AND_OLD_IMAGES)."
  value       = aws_dynamodb_table.executions.stream_arn
}

output "dynamodb_global_table_replica_arns" {
  description = "List of replica region names provisioned (ADR-0042 active-active). Empty when single-region."
  value       = [for r in keys(var.regions) : r if r != var.platform_region]
}

# ─── ALB (platform region) ──────────────────────────────────────────────────

output "alb_dns_name" {
  description = "Platform-region internal ALB DNS — reachable only from VPC (Client VPN)"
  value       = module.region_platform.alb_dns_name
}

output "alb_cert_arn" {
  description = "ACM ARN of the platform-region ALB's self-signed TLS certificate (ADR-0027)"
  value       = module.region_platform.alb_cert_arn
}

output "alb_self_signed_ca_pem" {
  description = "Self-signed CA cert PEM for the platform-region internal ALB. Save to a file and pass via `curl --cacert <file>`. Public material — not sensitive."
  value       = module.region_platform.alb_self_signed_ca_pem
}

# ─── ECR ──────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "Platform-region ECR repository URL for application images"
  value       = module.region_platform.ecr_repository_url
}

output "secondary_ecr_repository_url" {
  description = "Peer-region ECR repository URL (multi-region only). cloud-up.sh pushes the same image tag to both regions when a peer region is set."
  value       = local.has_peer ? module.region_peer[0].ecr_repository_url : null
}

# ─── Client VPN ───────────────────────────────────────────────────────────

output "client_vpn_endpoint_id" {
  description = "Platform-region AWS Client VPN endpoint identifier"
  value       = module.region_platform.client_vpn_endpoint_id
}

output "secondary_client_vpn_endpoint_id" {
  description = "Peer-region AWS Client VPN endpoint identifier (multi-region only)."
  value       = local.has_peer ? module.region_peer[0].client_vpn_endpoint_id : null
}

# ─── ECS ──────────────────────────────────────────────────────────────────

output "ecs_cluster_arn" {
  description = "Platform-region ECS Fargate cluster ARN"
  value       = module.region_platform.ecs_cluster_arn
}

# ─── VPC Endpoints (platform region) ──────────────────────────────────────

output "vpc_endpoint_ids" {
  description = "Platform-region VPC interface endpoint identifiers (PrivateLink — see ADR-0019)"
  value       = module.region_platform.vpc_endpoint_ids
}

output "s3_gateway_endpoint_id" {
  description = "Platform-region S3 gateway VPC endpoint identifier"
  value       = module.region_platform.s3_gateway_endpoint_id
}

output "dynamodb_gateway_endpoint_id" {
  description = "Platform-region DynamoDB gateway VPC endpoint identifier (ADR-0042)"
  value       = module.region_platform.dynamodb_gateway_endpoint_id
}

# ─── Async worker + distributed cache (ADR-0029 + ADR-0031) ─────────────────

output "valkey_endpoint" {
  description = "Platform-region ElastiCache Serverless Valkey endpoint (host:port) for the worker and app containers."
  value       = module.region_platform.valkey_endpoint
  sensitive   = true
}

output "sqs_primes_url" {
  description = "Platform-region SQS queue URL for the aegis-enclave-primes job queue."
  value       = module.region_platform.sqs_primes_url
}

output "worker_service_arn" {
  description = "ARN of the platform-region ECS service running the SQS consumer worker."
  value       = module.region_platform.worker_service_arn
}

output "bootstrap_task_arn" {
  description = "ARN of the platform-region ECS task definition for the cache bootstrap one-shot task."
  value       = module.region_platform.bootstrap_task_arn
}

# ─── CloudWatch dimension-resolution outputs (cloud-evidence.sh) ─────────────
# These are the *bare* identifiers AWS CloudWatch expects in metric dimensions,
# distinct from the ARNs / endpoints exported above.

output "valkey_cache_name" {
  description = "ElastiCache Serverless cache name — AWS/ElastiCache uses 'CacheName' (not 'CacheClusterId') as the dimension key for serverless caches."
  value       = module.region_platform.valkey_cache_name
}

output "ecs_cluster_name" {
  description = "Platform-region ECS cluster name (bare, not ARN) — used as the AWS/ECS 'ClusterName' dimension."
  value       = module.region_platform.ecs_cluster_name
}

output "alb_arn_suffix" {
  description = "Platform-region ALB ARN suffix in 'app/<name>/<id>' form — used as the AWS/ApplicationELB 'LoadBalancer' dimension."
  value       = module.region_platform.alb_arn_suffix
}

output "alb_target_group_arn_suffix" {
  description = "Platform-region ALB target group ARN suffix in 'targetgroup/<name>/<id>' form — used as the AWS/ApplicationELB 'TargetGroup' dimension."
  value       = module.region_platform.alb_target_group_arn_suffix
}

output "sqs_primes_name" {
  description = "Platform-region SQS queue bare name — used as the AWS/SQS 'QueueName' dimension."
  value       = module.region_platform.sqs_primes_name
}

output "worker_service_name" {
  description = "Platform-region ECS worker service bare name — used as the AWS/ECS 'ServiceName' dimension."
  value       = module.region_platform.worker_service_name
}

# ─── Multi-region outputs (conditional on a peer region in var.regions) ─────

output "secondary_alb_dns_name" {
  description = "Peer-region internal ALB DNS (multi-region only). null when single-region."
  value       = local.has_peer ? module.region_peer[0].alb_dns_name : null
}

output "secondary_alb_self_signed_ca_pem" {
  description = "Self-signed CA cert PEM for the peer-region internal ALB. null when single-region."
  value       = local.has_peer ? module.region_peer[0].alb_self_signed_ca_pem : null
}

output "secondary_ecs_cluster_name" {
  description = "Peer-region ECS cluster name (multi-region only)."
  value       = local.has_peer ? module.region_peer[0].ecs_cluster_name : null
}

output "secondary_sqs_primes_url" {
  description = "Peer-region SQS queue URL (multi-region only). Region-local — does not cross-replicate."
  value       = local.has_peer ? module.region_peer[0].sqs_primes_url : null
}

output "secondary_valkey_endpoint" {
  description = "Peer-region ElastiCache Serverless Valkey endpoint (multi-region only)."
  value       = local.has_peer ? module.region_peer[0].valkey_endpoint : null
  sensitive   = true
}

# ─── Route53 outputs (conditional on a peer region + route53_zone_name) ─────

output "route53_record_names" {
  description = "Route53 weighted A record FQDNs (platform + peer) when route53_zone_name is set. Empty list otherwise."
  value = local.route53_enabled ? [
    aws_route53_record.platform[0].fqdn,
    aws_route53_record.peer[0].fqdn,
  ] : []
}

output "route53_health_check_ids" {
  description = "Route53 health check IDs (platform + peer) when multi-region + route53_zone_name set."
  value = local.route53_enabled ? {
    primary   = aws_route53_health_check.platform[0].id
    secondary = aws_route53_health_check.peer[0].id
  } : {}
}

# ─── Cost guardrail (see budget.tf) ─────────────────────────────────────────

output "monthly_budget" {
  description = "AWS Budgets cost guardrail: ceiling in USD and whether email notifications are armed (false = silent cost tracker)."
  value = {
    limit_usd     = var.monthly_budget_usd
    notifications = var.budget_notification_email != ""
    budget_name   = aws_budgets_budget.monthly.name
  }
}
