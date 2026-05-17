# outputs.tf — surfaced values from the composition.
#
# Implements the ADR-0042 greenfield DynamoDB target: DynamoDB outputs
# replace any prior relational-DB outputs; multi-region outputs are
# conditional and return null when secondary_region is empty.

output "vpc_id" {
  description = "Primary VPC identifier"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Primary VPC private subnet IDs across 3 AZs"
  value       = module.vpc.private_subnets
}

# ─── DynamoDB executions table ────────────────────────────────────────────

output "dynamodb_table_name" {
  description = "DynamoDB executions table name (ADR-0042). App + worker reach it via DYNAMODB_TABLE_NAME env var."
  value       = aws_dynamodb_table.executions.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB executions table ARN (primary region)."
  value       = aws_dynamodb_table.executions.arn
}

output "dynamodb_stream_arn" {
  description = "DynamoDB stream ARN — V2 hook for archival to S3 / event-driven downstream consumers (NEW_AND_OLD_IMAGES)."
  value       = aws_dynamodb_table.executions.stream_arn
}

output "dynamodb_global_table_replica_arns" {
  description = "List of replica region names provisioned (ADR-0042 active-active). Empty when secondary_region is unset."
  value       = var.secondary_region != "" ? [var.secondary_region] : []
}

# ─── ALB (primary) ────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "Primary internal ALB DNS — reachable only from VPC (Client VPN)"
  value       = module.alb.dns_name
}

output "alb_cert_arn" {
  description = "ACM ARN of the primary ALB's self-signed TLS certificate (ADR-0027)"
  value       = aws_acm_certificate.alb.arn
}

output "alb_self_signed_ca_pem" {
  description = "Self-signed CA cert PEM for the primary internal ALB. Save to a file and pass via `curl --cacert <file>` so the operator avoids `-k` and the cert chain is explicit. Public material — not sensitive."
  value       = tls_self_signed_cert.alb.cert_pem
}

# ─── ECR ──────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "Primary ECR repository URL for application images"
  value       = module.ecr.repository_url
}

output "secondary_ecr_repository_url" {
  description = "Secondary ECR repository URL (multi-region only). cloud-up.sh pushes the same image tag to both regions when secondary_region is set."
  value       = local.is_multi_region == 1 ? aws_ecr_repository.secondary[0].repository_url : null
}

# ─── Client VPN ───────────────────────────────────────────────────────────

output "client_vpn_endpoint_id" {
  description = "Primary AWS Client VPN endpoint identifier"
  value       = aws_ec2_client_vpn_endpoint.main.id
}

output "secondary_client_vpn_endpoint_id" {
  description = "Secondary AWS Client VPN endpoint identifier (multi-region only)."
  value       = local.is_multi_region == 1 ? aws_ec2_client_vpn_endpoint.secondary[0].id : null
}

# ─── ECS ──────────────────────────────────────────────────────────────────

output "ecs_cluster_arn" {
  description = "Primary ECS Fargate cluster ARN"
  value       = module.ecs.cluster_arn
}

# ─── VPC Endpoints ────────────────────────────────────────────────────────

output "vpc_endpoint_ids" {
  description = "Primary VPC interface endpoint identifiers (PrivateLink — see ADR-0019)"
  value       = { for k, v in aws_vpc_endpoint.interfaces : k => v.id }
}

output "s3_gateway_endpoint_id" {
  description = "Primary S3 gateway VPC endpoint identifier"
  value       = aws_vpc_endpoint.s3.id
}

output "dynamodb_gateway_endpoint_id" {
  description = "Primary DynamoDB gateway VPC endpoint identifier (ADR-0042)"
  value       = aws_vpc_endpoint.dynamodb.id
}

# ─── Async worker + distributed cache (ADR-0029 + ADR-0031) ─────────────────

output "valkey_endpoint" {
  description = "Primary ElastiCache Serverless Valkey endpoint (host:port) for the worker and app containers."
  value       = "${aws_elasticache_serverless_cache.valkey.endpoint[0].address}:${aws_elasticache_serverless_cache.valkey.endpoint[0].port}"
  sensitive   = true
}

output "sqs_primes_url" {
  description = "Primary SQS queue URL for the aegis-enclave-primes job queue."
  value       = aws_sqs_queue.primes.url
}

output "worker_service_arn" {
  description = "ARN of the primary ECS service running the SQS consumer worker."
  value       = aws_ecs_service.worker.id
}

output "bootstrap_task_arn" {
  description = "ARN of the primary ECS task definition for the cache bootstrap one-shot task."
  value       = aws_ecs_task_definition.cache_bootstrap.arn
}

# ─── CloudWatch dimension-resolution outputs (cloud-evidence.sh) ─────────────
# These are the *bare* identifiers AWS CloudWatch expects in metric dimensions,
# distinct from the ARNs / endpoints exported above.

output "valkey_cache_name" {
  description = "ElastiCache Serverless cache name — AWS/ElastiCache uses 'CacheName' (not 'CacheClusterId') as the dimension key for serverless caches."
  value       = aws_elasticache_serverless_cache.valkey.name
}

output "ecs_cluster_name" {
  description = "Primary ECS cluster name (bare, not ARN) — used as the AWS/ECS 'ClusterName' dimension."
  value       = module.ecs.cluster_name
}

output "alb_arn_suffix" {
  description = "Primary ALB ARN suffix in 'app/<name>/<id>' form — used as the AWS/ApplicationELB 'LoadBalancer' dimension."
  value       = module.alb.arn_suffix
}

output "alb_target_group_arn_suffix" {
  description = "Primary ALB target group ARN suffix in 'targetgroup/<name>/<id>' form — used as the AWS/ApplicationELB 'TargetGroup' dimension."
  value       = module.alb.target_groups["app"].arn_suffix
}

output "sqs_primes_name" {
  description = "Primary SQS queue bare name — used as the AWS/SQS 'QueueName' dimension."
  value       = aws_sqs_queue.primes.name
}

output "worker_service_name" {
  description = "Primary ECS worker service bare name — used as the AWS/ECS 'ServiceName' dimension."
  value       = aws_ecs_service.worker.name
}

# ─── Multi-region outputs (conditional on secondary_region != "") ─────────

output "secondary_alb_dns_name" {
  description = "Secondary internal ALB DNS (multi-region only). null when secondary_region is empty."
  value       = local.is_multi_region == 1 ? aws_lb.secondary[0].dns_name : null
}

output "secondary_alb_self_signed_ca_pem" {
  description = "Self-signed CA cert PEM for the secondary internal ALB. null when secondary_region is empty."
  value       = local.is_multi_region == 1 ? tls_self_signed_cert.secondary_alb[0].cert_pem : null
}

output "secondary_ecs_cluster_name" {
  description = "Secondary ECS cluster name (multi-region only)."
  value       = local.is_multi_region == 1 ? aws_ecs_cluster.secondary[0].name : null
}

output "secondary_sqs_primes_url" {
  description = "Secondary SQS queue URL (multi-region only). Region-local — does not cross-replicate."
  value       = local.is_multi_region == 1 ? aws_sqs_queue.secondary_primes[0].url : null
}

output "secondary_valkey_endpoint" {
  description = "Secondary ElastiCache Serverless Valkey endpoint (multi-region only)."
  value       = local.is_multi_region == 1 ? "${aws_elasticache_serverless_cache.secondary_valkey[0].endpoint[0].address}:${aws_elasticache_serverless_cache.secondary_valkey[0].endpoint[0].port}" : null
  sensitive   = true
}

# ─── Route53 outputs (conditional on secondary_region + route53_zone_name) ─

output "route53_record_names" {
  description = "Route53 weighted A record FQDNs (primary + secondary) when route53_zone_name is set. Empty list otherwise."
  value = local.multi_region_count == 1 ? [
    aws_route53_record.primary[0].fqdn,
    aws_route53_record.secondary[0].fqdn,
  ] : []
}

output "route53_health_check_ids" {
  description = "Route53 health check IDs (primary + secondary) when multi-region + route53_zone_name set."
  value = local.multi_region_count == 1 ? {
    primary   = aws_route53_health_check.primary[0].id
    secondary = aws_route53_health_check.secondary[0].id
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
