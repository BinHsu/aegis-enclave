# main.tf — root composition for the aegis-enclave deployment.
#
# Implements the ADR-0042 greenfield DynamoDB Global Tables active-active
# multi-region target.
#
# Two layers, ONE Terraform config / ONE apply / ONE state:
#
#   Platform layer (this file + budget.tf):
#     - terraform{} block + providers
#     - aws_dynamodb_table.executions (Global Table; replica per peer region)
#     - Route53 (zone lookup, health checks, weighted A records)
#     - aws_budgets_budget (budget.tf)
#   DynamoDB Global Tables is a single logical resource, so a single-config /
#   single-state deployment is mandatory — the regions are NOT split into
#   separate state.
#
#   Regional layer (modules/region-stack/):
#     - VPC, subnets, route tables, all security groups, VPC endpoints
#     - ALB + self-signed TLS cert, ECS cluster + services + task defs +
#       autoscaling, IAM roles, SQS, ElastiCache Valkey, ECR, Client VPN,
#       CloudWatch log groups + alarms + SNS topic, the bootstrap null_resource
#   One module instance per region in var.regions.
#
# Provider mechanics:
#   Terraform cannot pass a per-instance provider to a for_each/count module,
#   so the region-stack module is instantiated with EXPLICIT module calls —
#   `module.region_platform` (provider = aws) and `module.region_peer`
#   (provider = aws.peer, count-gated on a peer region being present).
#
# Plan-only deliverable per ADR-0015 outside the bounded cloud-acceptance
# window (ADR-0034 supersedes the plan-only stance for that window).

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.46"
      configuration_aliases = [aws.peer]
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # ─── Remote state backend (commented out; see ADR-0025) ──────────────
  # Uncomment and fill in `bucket` + `dynamodb_table` from the outputs of
  # `terraform/bootstrap/` after running it once. The case-study deliverable
  # runs `terraform plan -backend=false`, so this stays commented out by
  # default; forkers adopting the deployment for production should enable it.
  #
  # backend "s3" {
  #   bucket         = "aegis-enclave-tfstate-xxxxxxxx"   # bootstrap output
  #   key            = "main/terraform.tfstate"
  #   region         = "eu-central-1"
  #   encrypt        = true
  #   dynamodb_table = "aegis-enclave-tflock"             # bootstrap output
  # }
}

# ─── Region wiring ──────────────────────────────────────────────────────────
# The platform region is one key in var.regions; the peer region (if any) is
# the other. Single-region scope = a one-entry map => peer_region == "".
locals {
  peer_regions = [for r in keys(var.regions) : r if r != var.platform_region]
  peer_region  = length(local.peer_regions) > 0 ? local.peer_regions[0] : ""
  has_peer     = local.peer_region != ""

  # Route53 weighted records only when a hosted zone is supplied.
  has_route53 = var.route53_zone_name != ""

  # Region-suffixed resource names keep account-global names (ECS clusters,
  # SQS queues, IAM roles, ...) unique when two stacks run in one account.
  platform_name_prefix = "aegis-enclave"
  peer_name_prefix     = "aegis-enclave-${local.peer_region}"

  common_tags = {
    Project     = "aegis-enclave"
    Environment = var.environment
    ManagedBy   = "terraform"
    CostCenter  = var.cost_center
    Owner       = var.owner
    Repository  = "github.com/BinHsu/aegis-enclave"
  }
}

provider "aws" {
  region = var.platform_region

  default_tags {
    tags = local.common_tags
  }
}

# Peer-region provider — always declared (Terraform requires aliased providers
# to be present even when count-conditional). When no peer region is in
# var.regions, the provider points at the platform region and no peer
# resources are provisioned (the region_peer module call is count = 0).
provider "aws" {
  alias  = "peer"
  region = local.has_peer ? local.peer_region : var.platform_region

  default_tags {
    tags = merge(local.common_tags, { Region = "peer" })
  }
}

data "aws_caller_identity" "current" {}

# ═══════════════════════════════════════════════════════════════════════════
# PLATFORM LAYER — DynamoDB Global Table
# ═══════════════════════════════════════════════════════════════════════════
# Greenfield DDB choice (ADR-0042). PAY_PER_REQUEST keeps the workload
# bursty-shape friendly; stream enabled for V2 archival hooks. The dynamic
# `replica` block adds every non-platform region in var.regions, making the
# table active-active.
resource "aws_dynamodb_table" "executions" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "execution_id"

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "execution_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  # PoC scope: SSE with the AWS-owned key. Customer-managed KMS is a
  # production-hardening upgrade (ADR-0003 PoC-scope / prod-hygiene calibration).
  #tfsec:ignore:aws-dynamodb-table-customer-key
  server_side_encryption {
    enabled = true
  }

  # One replica per non-platform region — Global Tables active-active.
  dynamic "replica" {
    for_each = toset(local.peer_regions)
    content {
      region_name            = replica.value
      point_in_time_recovery = true
    }
  }

  tags = { Name = "aegis-enclave-executions" }
}

# ═══════════════════════════════════════════════════════════════════════════
# REGIONAL LAYER — one region-stack instance per region
# ═══════════════════════════════════════════════════════════════════════════
# Explicit module calls (not for_each) because each instance needs a distinct
# provider. Adding a third region requires a third module call + a third
# provider alias here (var.regions validation caps the map at 2 to make this
# constraint loud).

module "region_platform" {
  source = "./modules/region-stack"

  providers = {
    aws = aws
    tls = tls
  }

  region          = var.platform_region
  name_prefix     = local.platform_name_prefix
  vpc_cidr        = var.regions[var.platform_region].vpc_cidr
  vpn_client_cidr = var.regions[var.platform_region].vpn_client_cidr
  server_cert_arn = var.regions[var.platform_region].server_cert_arn
  client_cert_arn = var.regions[var.platform_region].client_cert_arn

  alb_internal_hostname = var.alb_internal_hostname

  dynamodb_table_name = aws_dynamodb_table.executions.name
  dynamodb_table_arn  = aws_dynamodb_table.executions.arn
  account_id          = data.aws_caller_identity.current.account_id

  image_tag                     = var.image_tag
  worker_min_count              = var.worker_min_count
  worker_max_count              = var.worker_max_count
  backpressure_threshold_factor = var.backpressure_threshold_factor
  sqs_visibility_timeout        = var.sqs_visibility_timeout
  valkey_max_storage_gb         = var.valkey_max_storage_gb
  valkey_max_ecpu_per_sec       = var.valkey_max_ecpu_per_sec
  alarm_email                   = var.alarm_email
}

module "region_peer" {
  source = "./modules/region-stack"
  count  = local.has_peer ? 1 : 0

  providers = {
    aws = aws.peer
    tls = tls
  }

  region          = local.peer_region
  name_prefix     = local.peer_name_prefix
  vpc_cidr        = var.regions[local.peer_region].vpc_cidr
  vpn_client_cidr = var.regions[local.peer_region].vpn_client_cidr
  server_cert_arn = var.regions[local.peer_region].server_cert_arn
  client_cert_arn = var.regions[local.peer_region].client_cert_arn

  alb_internal_hostname = var.alb_internal_hostname

  dynamodb_table_name = aws_dynamodb_table.executions.name
  dynamodb_table_arn  = aws_dynamodb_table.executions.arn
  account_id          = data.aws_caller_identity.current.account_id

  image_tag                     = var.image_tag
  worker_min_count              = var.worker_min_count
  worker_max_count              = var.worker_max_count
  backpressure_threshold_factor = var.backpressure_threshold_factor
  sqs_visibility_timeout        = var.sqs_visibility_timeout
  valkey_max_storage_gb         = var.valkey_max_storage_gb
  valkey_max_ecpu_per_sec       = var.valkey_max_ecpu_per_sec
  alarm_email                   = var.alarm_email
}

# ═══════════════════════════════════════════════════════════════════════════
# PLATFORM LAYER — Route53 (multi-region only; weighted A records + health)
# ═══════════════════════════════════════════════════════════════════════════
# Conditional on BOTH a peer region AND route53_zone_name. The forker provides
# an existing hosted zone via var.route53_zone_name; we look it up and create
# one weighted A record + one CLOUDWATCH_METRIC health check per region.
#
# Health checks target each region's ALB via a CloudWatch alarm on the ALB's
# `HealthyHostCount` metric — internal ALBs are not reachable by Route53's
# public health checkers, so the alarm-backed health check keeps the signal
# on-VPC without exposing a public health endpoint.

locals {
  route53_enabled = local.has_peer && local.has_route53
}

data "aws_route53_zone" "main" {
  count = local.route53_enabled ? 1 : 0

  name         = var.route53_zone_name
  private_zone = false
}

# Per-region ALB health alarm. The platform region's alarm uses the default
# provider; the peer region's alarm must be created in the peer region (the
# CLOUDWATCH_METRIC health check reads the alarm from its own region). We use
# two explicit resources rather than for_each because of the provider split.
resource "aws_cloudwatch_metric_alarm" "alb_health_platform" {
  count = local.route53_enabled ? 1 : 0

  alarm_name          = "aegis-enclave-${var.platform_region}-alb-health"
  alarm_description   = "Platform-region ALB has 0 healthy targets - Route53 health check feeds off this."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "breaching"

  metric_name = "HealthyHostCount"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Maximum"

  dimensions = {
    LoadBalancer = module.region_platform.alb_arn_suffix
    TargetGroup  = module.region_platform.alb_target_group_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_health_peer" {
  count    = local.route53_enabled ? 1 : 0
  provider = aws.peer

  alarm_name          = "aegis-enclave-${local.peer_region}-alb-health"
  alarm_description   = "Peer-region ALB has 0 healthy targets - Route53 health check feeds off this."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "breaching"

  metric_name = "HealthyHostCount"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Maximum"

  dimensions = {
    LoadBalancer = module.region_peer[0].alb_arn_suffix
    TargetGroup  = module.region_peer[0].alb_target_group_arn_suffix
  }
}

resource "aws_route53_health_check" "platform" {
  count = local.route53_enabled ? 1 : 0

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.alb_health_platform[0].alarm_name
  cloudwatch_alarm_region         = var.platform_region
  insufficient_data_health_status = "Unhealthy"

  tags = { Name = "aegis-enclave-${var.platform_region}-health" }
}

resource "aws_route53_health_check" "peer" {
  count = local.route53_enabled ? 1 : 0

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.alb_health_peer[0].alarm_name
  cloudwatch_alarm_region         = local.peer_region
  insufficient_data_health_status = "Unhealthy"

  tags = { Name = "aegis-enclave-${local.peer_region}-health" }
}

# Weighted records — 50/50 split. Each record aliases its region's ALB DNS.
# Route53 stops returning an alias when its health check goes unhealthy.
resource "aws_route53_record" "platform" {
  count = local.route53_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.alb_internal_hostname
  type    = "A"

  set_identifier = "platform-${var.platform_region}"
  weighted_routing_policy {
    weight = 50
  }

  alias {
    name                   = module.region_platform.alb_dns_name
    zone_id                = module.region_platform.alb_zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.platform[0].id
}

resource "aws_route53_record" "peer" {
  count = local.route53_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.alb_internal_hostname
  type    = "A"

  set_identifier = "peer-${local.peer_region}"
  weighted_routing_policy {
    weight = 50
  }

  alias {
    name                   = module.region_peer[0].alb_dns_name
    zone_id                = module.region_peer[0].alb_zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.peer[0].id
}
