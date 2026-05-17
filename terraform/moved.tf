# moved.tf — state-migration map for the region-stack refactor.
#
# Pre-refactor, every per-region resource lived at the root as a primary block
# plus a count-gated `secondary_*` block. They now live inside the
# `region-stack` module (module.region_platform for the home region,
# module.region_peer[0] for the peer region).
#
# The repo itself ships plan-only (no committed state), so these blocks are
# for FORKERS who already ran `terraform apply` against the old layout: the
# `moved` blocks let `terraform plan` recognise the resources as relocated
# rather than destroy-and-recreate.
#
# Scope note: the PLATFORM-region blocks are clean 1:1 relocations (same
# resource implementation, just nested into the module). The PEER-region map
# only covers resources whose implementation is type-compatible across the
# refactor (SQS, Valkey, IAM, ECS task defs/services, Client VPN, log groups).
# The old peer region used INLINE aws_vpc / aws_subnet / aws_lb / aws_ecs_cluster
# resources where the module now uses community modules (module.vpc /
# module.alb / module.ecs); Terraform cannot `moved` across those differing
# implementations, so a forker upgrading a multi-region deployment will see the
# peer VPC/ALB/ECS-cluster recreated. That is acceptable: the case-study repo
# is plan-only and no forker is known to run the old multi-region layout.

# ═══════════════════════════════════════════════════════════════════════════
# PLATFORM REGION (old root "primary" resources -> module.region_platform)
# ═══════════════════════════════════════════════════════════════════════════

moved {
  from = module.vpc
  to   = module.region_platform.module.vpc
}

moved {
  from = module.vpc_endpoints_sg
  to   = module.region_platform.module.vpc_endpoints_sg
}

moved {
  from = module.alb_sg
  to   = module.region_platform.module.alb_sg
}

moved {
  from = module.app_sg
  to   = module.region_platform.module.app_sg
}

moved {
  from = module.alb
  to   = module.region_platform.module.alb
}

moved {
  from = module.ecs
  to   = module.region_platform.module.ecs
}

moved {
  from = module.ecr
  to   = module.region_platform.module.ecr
}

moved {
  from = aws_vpc_endpoint.s3
  to   = module.region_platform.aws_vpc_endpoint.s3
}

moved {
  from = aws_vpc_endpoint.dynamodb
  to   = module.region_platform.aws_vpc_endpoint.dynamodb
}

moved {
  from = aws_vpc_endpoint.interfaces
  to   = module.region_platform.aws_vpc_endpoint.interfaces
}

moved {
  from = tls_private_key.alb
  to   = module.region_platform.tls_private_key.alb
}

moved {
  from = tls_self_signed_cert.alb
  to   = module.region_platform.tls_self_signed_cert.alb
}

moved {
  from = aws_acm_certificate.alb
  to   = module.region_platform.aws_acm_certificate.alb
}

moved {
  from = aws_ec2_client_vpn_endpoint.main
  to   = module.region_platform.aws_ec2_client_vpn_endpoint.main
}

moved {
  from = aws_ec2_client_vpn_authorization_rule.vpc_access
  to   = module.region_platform.aws_ec2_client_vpn_authorization_rule.vpc_access
}

# The three named per-AZ associations collapse into a count-indexed resource.
moved {
  from = aws_ec2_client_vpn_network_association.primary_az
  to   = module.region_platform.aws_ec2_client_vpn_network_association.az[0]
}

moved {
  from = aws_ec2_client_vpn_network_association.secondary_az
  to   = module.region_platform.aws_ec2_client_vpn_network_association.az[1]
}

moved {
  from = aws_ec2_client_vpn_network_association.tertiary_az
  to   = module.region_platform.aws_ec2_client_vpn_network_association.az[2]
}

moved {
  from = aws_sqs_queue.primes
  to   = module.region_platform.aws_sqs_queue.primes
}

moved {
  from = aws_sqs_queue.primes_dlq
  to   = module.region_platform.aws_sqs_queue.primes_dlq
}

moved {
  from = aws_security_group.valkey
  to   = module.region_platform.aws_security_group.valkey
}

moved {
  from = aws_security_group.worker
  to   = module.region_platform.aws_security_group.worker
}

moved {
  from = aws_security_group_rule.app_to_valkey
  to   = module.region_platform.aws_security_group_rule.app_to_valkey
}

moved {
  from = aws_security_group_rule.worker_to_valkey
  to   = module.region_platform.aws_security_group_rule.worker_to_valkey
}

moved {
  from = aws_elasticache_serverless_cache.valkey
  to   = module.region_platform.aws_elasticache_serverless_cache.valkey
}

moved {
  from = aws_iam_role.worker
  to   = module.region_platform.aws_iam_role.worker
}

moved {
  from = aws_iam_role_policy.worker_inline
  to   = module.region_platform.aws_iam_role_policy.worker_inline
}

moved {
  from = aws_iam_role_policy_attachment.worker_ecr
  to   = module.region_platform.aws_iam_role_policy_attachment.worker_ecr
}

moved {
  from = aws_iam_role_policy_attachment.worker_logs
  to   = module.region_platform.aws_iam_role_policy_attachment.worker_logs
}

moved {
  from = aws_ecs_task_definition.worker
  to   = module.region_platform.aws_ecs_task_definition.worker
}

moved {
  from = aws_ecs_task_definition.cache_bootstrap
  to   = module.region_platform.aws_ecs_task_definition.cache_bootstrap
}

moved {
  from = aws_ecs_service.worker
  to   = module.region_platform.aws_ecs_service.worker
}

moved {
  from = aws_appautoscaling_target.worker
  to   = module.region_platform.aws_appautoscaling_target.worker
}

moved {
  from = aws_appautoscaling_policy.target_tracking
  to   = module.region_platform.aws_appautoscaling_policy.target_tracking
}

moved {
  from = aws_cloudwatch_log_group.app
  to   = module.region_platform.aws_cloudwatch_log_group.app
}

moved {
  from = aws_cloudwatch_log_group.worker
  to   = module.region_platform.aws_cloudwatch_log_group.worker
}

moved {
  from = aws_cloudwatch_log_group.bootstrap
  to   = module.region_platform.aws_cloudwatch_log_group.bootstrap
}

moved {
  from = null_resource.run_cache_bootstrap
  to   = module.region_platform.null_resource.run_cache_bootstrap
}

moved {
  from = aws_sns_topic.alarms
  to   = module.region_platform.aws_sns_topic.alarms
}

moved {
  from = aws_sns_topic_subscription.alarms_email
  to   = module.region_platform.aws_sns_topic_subscription.alarms_email
}

moved {
  from = aws_cloudwatch_metric_alarm.dlq_depth
  to   = module.region_platform.aws_cloudwatch_metric_alarm.dlq_depth
}

moved {
  from = aws_cloudwatch_metric_alarm.slo_fast_burn
  to   = module.region_platform.aws_cloudwatch_metric_alarm.slo_fast_burn
}

moved {
  from = aws_cloudwatch_metric_alarm.slo_slow_burn
  to   = module.region_platform.aws_cloudwatch_metric_alarm.slo_slow_burn
}

moved {
  from = aws_cloudwatch_composite_alarm.slo_breach
  to   = module.region_platform.aws_cloudwatch_composite_alarm.slo_breach
}

moved {
  from = aws_cloudwatch_metric_alarm.latency_p99_breach
  to   = module.region_platform.aws_cloudwatch_metric_alarm.latency_p99_breach
}

moved {
  from = aws_cloudwatch_metric_alarm.cache_hit_ratio_low
  to   = module.region_platform.aws_cloudwatch_metric_alarm.cache_hit_ratio_low
}

moved {
  from = aws_cloudwatch_metric_alarm.compute_p95_breach
  to   = module.region_platform.aws_cloudwatch_metric_alarm.compute_p95_breach
}

moved {
  from = aws_cloudwatch_dashboard.slo
  to   = module.region_platform.aws_cloudwatch_dashboard.slo
}

# ═══════════════════════════════════════════════════════════════════════════
# PEER REGION (old root "secondary_*" resources -> module.region_peer[0])
# ═══════════════════════════════════════════════════════════════════════════
# Only type-compatible relocations are listed. Inline VPC / subnet / route
# table / ALB / ECS-cluster resources are intentionally omitted — the module
# uses community modules for those, an implementation change Terraform cannot
# express as a `moved` (see the header note).

moved {
  from = aws_sqs_queue.secondary_primes[0]
  to   = module.region_peer[0].aws_sqs_queue.primes
}

moved {
  from = aws_sqs_queue.secondary_primes_dlq[0]
  to   = module.region_peer[0].aws_sqs_queue.primes_dlq
}

moved {
  from = aws_security_group.secondary_worker[0]
  to   = module.region_peer[0].aws_security_group.worker
}

moved {
  from = aws_security_group.secondary_valkey[0]
  to   = module.region_peer[0].aws_security_group.valkey
}

moved {
  from = aws_elasticache_serverless_cache.secondary_valkey[0]
  to   = module.region_peer[0].aws_elasticache_serverless_cache.valkey
}

moved {
  from = aws_iam_role.secondary_worker[0]
  to   = module.region_peer[0].aws_iam_role.worker
}

moved {
  from = aws_iam_role_policy.secondary_worker_inline[0]
  to   = module.region_peer[0].aws_iam_role_policy.worker_inline
}

moved {
  from = aws_iam_role_policy_attachment.secondary_worker_ecr[0]
  to   = module.region_peer[0].aws_iam_role_policy_attachment.worker_ecr
}

moved {
  from = aws_iam_role_policy_attachment.secondary_worker_logs[0]
  to   = module.region_peer[0].aws_iam_role_policy_attachment.worker_logs
}

moved {
  from = aws_ecs_task_definition.secondary_worker[0]
  to   = module.region_peer[0].aws_ecs_task_definition.worker
}

moved {
  from = aws_ecs_task_definition.secondary_bootstrap[0]
  to   = module.region_peer[0].aws_ecs_task_definition.cache_bootstrap
}

moved {
  from = aws_cloudwatch_log_group.secondary_app[0]
  to   = module.region_peer[0].aws_cloudwatch_log_group.app
}

moved {
  from = aws_cloudwatch_log_group.secondary_worker[0]
  to   = module.region_peer[0].aws_cloudwatch_log_group.worker
}

moved {
  from = aws_cloudwatch_log_group.secondary_bootstrap[0]
  to   = module.region_peer[0].aws_cloudwatch_log_group.bootstrap
}

moved {
  from = aws_ec2_client_vpn_endpoint.secondary[0]
  to   = module.region_peer[0].aws_ec2_client_vpn_endpoint.main
}

moved {
  from = aws_ec2_client_vpn_authorization_rule.secondary_vpc_access[0]
  to   = module.region_peer[0].aws_ec2_client_vpn_authorization_rule.vpc_access
}

moved {
  from = aws_ec2_client_vpn_network_association.secondary_az_a[0]
  to   = module.region_peer[0].aws_ec2_client_vpn_network_association.az[0]
}

moved {
  from = aws_ec2_client_vpn_network_association.secondary_az_b[0]
  to   = module.region_peer[0].aws_ec2_client_vpn_network_association.az[1]
}

moved {
  from = aws_ec2_client_vpn_network_association.secondary_az_c[0]
  to   = module.region_peer[0].aws_ec2_client_vpn_network_association.az[2]
}
