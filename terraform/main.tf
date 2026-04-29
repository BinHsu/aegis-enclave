# main.tf — composition for the aegis-enclave deployment.
#
# Implements the ADR-0042 greenfield DynamoDB Global Tables active-active
# multi-region target.
#
# Topology (single-region scope: secondary_region = ""):
#   - Primary VPC (3-AZ private subnets), ALB (private), ECS Fargate (app + worker)
#   - DynamoDB table `executions` (PAY_PER_REQUEST, stream enabled, TTL via ttl_at)
#   - ElastiCache Serverless Valkey, SQS primes + DLQ
#   - Client VPN endpoint (mutual-TLS, ACM-imported certs)
#   - 8 VPC interface endpoints + S3 gateway endpoint (private-only egress)
#
# Multi-region scope (secondary_region = "eu-west-1"):
#   - Primary mirror as above
#   - Secondary mirror via `count = local.is_multi_region ? 1 : 0` blocks below
#   - DynamoDB `replica` block adds the secondary region (Global Tables active-active)
#   - Optional Route53 weighted A records (50/50) with per-ALB health checks
#
# Plan-only deliverable per ADR-0015 outside the bounded cloud-acceptance
# window (ADR-0034 supersedes the original plan-only stance for that window).
# Cross-cloud migration spec lives in `docs/migration_runbook.md`.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.50"
      configuration_aliases = [aws.secondary]
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

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aegis-enclave"
      Environment = var.environment
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
      Owner       = var.owner
      Repository  = "github.com/BinHsu/aegis-enclave"
    }
  }
}

# Secondary-region provider — always declared (terraform requires aliased
# providers to be present even when count-conditional). When secondary_region
# is empty, no secondary resources are provisioned, and the provider is a
# no-op pointing at the primary region by default.
provider "aws" {
  alias  = "secondary"
  region = var.secondary_region != "" ? var.secondary_region : var.region

  default_tags {
    tags = {
      Project     = "aegis-enclave"
      Environment = var.environment
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
      Owner       = var.owner
      Repository  = "github.com/BinHsu/aegis-enclave"
      Region      = "secondary"
    }
  }
}

# ─── Multi-region toggle ──────────────────────────────────────────────────
# Single source of truth for "are we provisioning the secondary mirror?".
# Used as `count = local.is_multi_region ? 1 : 0` on the conditional blocks.
locals {
  is_multi_region    = var.secondary_region != "" ? 1 : 0
  has_route53        = var.route53_zone_name != "" ? 1 : 0
  multi_region_count = local.is_multi_region * local.has_route53 # Route53 only with both
}

# ═══════════════════════════════════════════════════════════════════════════
# PRIMARY REGION
# ═══════════════════════════════════════════════════════════════════════════

# ─── Network (ADR-0007 reconsidered: 3-AZ private posture) ──────────────
# ADR-0019 — Private-only VPC: no public subnets, no IGW, no NAT.
# AWS service egress goes through VPC Endpoints (declared below); the VPC
# has no public-internet egress path at all.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0" # exact pin (case-study reproducibility); was ~> 5.8

  name = "aegis-enclave-vpc"
  cidr = var.vpc_cidr

  # ADR-0007 reconsidered (04/28): 3 AZs. ECS spreads tasks across 3 fault
  # domains; AZ loss leaves 2/3 capacity. The DDB-pivot (ADR-0042) does not
  # change this posture — DDB is multi-AZ implicit, but we still need 3 ECS
  # subnets. database_subnets removed (no RDS); 3 private subnets only.
  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  # public_subnets intentionally absent — see ADR-0019.
  # database_subnets intentionally absent — see ADR-0042 (DDB is regional-managed).

  enable_nat_gateway   = false # ADR-0019 — no public-internet egress
  enable_dns_hostnames = true
  enable_dns_support   = true # required for VPC Endpoints to resolve
}

# ─── VPC Endpoints (ADR-0019: private-only VPC, AWS API egress via PrivateLink) ──

# Security group permitting HTTPS from the VPC CIDR to the endpoint ENIs.
module "vpc_endpoints_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.1" # exact pin (case-study reproducibility); was ~> 5.2

  name        = "aegis-enclave-vpc-endpoints-sg"
  description = "VPC Endpoint ENI inbound - HTTPS from within the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.vpc_cidr]
  ingress_rules       = ["https-443-tcp"]
  egress_rules        = ["all-all"]
}

# Gateway endpoints — S3 + DynamoDB (free; ECR uses S3 for layer storage,
# DynamoDB-pivot routes app/worker SDK traffic via this gateway endpoint).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "aegis-enclave-s3-gateway" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "aegis-enclave-dynamodb-gateway" }
}

# Interface endpoints — for AWS service APIs that the workload calls.
# 8 endpoints per ADR-0019 (ecr.api / ecr.dkr / secretsmanager / logs / ecs /
# ecs-agent / ecs-telemetry / sts / sqs). secretsmanager retained for forker
# extensions; the DDB-pivot itself does not use Secrets Manager (no DB password).
locals {
  interface_endpoints = toset([
    "ecr.api",
    "ecr.dkr",
    "secretsmanager",
    "logs",
    "ecs",
    "ecs-agent",
    "ecs-telemetry",
    "sts",
    "sqs",
  ])
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each = local.interface_endpoints

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [module.vpc_endpoints_sg.security_group_id]
  private_dns_enabled = true

  tags = { Name = "aegis-enclave-${replace(each.value, ".", "-")}" }
}

# ─── Security groups (ALB → app chain; no RDS SG per ADR-0042) ─────────────
module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.1" # exact pin (case-study reproducibility); was ~> 5.2

  name        = "aegis-enclave-alb-sg"
  description = "Internal ALB - reachable only from VPC (Client VPN clients arrive via VPC routes)"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.vpc_cidr]
  ingress_rules       = ["https-443-tcp"] # ADR-0027 — HTTPS-only listener; HTTP not exposed.
  egress_rules        = ["all-all"]
}

module "app_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.1" # exact pin (case-study reproducibility); was ~> 5.2

  name        = "aegis-enclave-app-sg"
  description = "Application service - accept traffic only from internal ALB"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [{
    from_port                = 8000
    to_port                  = 8000
    protocol                 = "tcp"
    description              = "App port from ALB"
    source_security_group_id = module.alb_sg.security_group_id
  }]
  egress_rules = ["all-all"]
}

# ─── Data layer — DynamoDB Global Tables (ADR-0042) ────────────────────────
# Greenfield DDB choice (ADR-0042 supersedes any prior relational-DB plan).
# Dynamic `replica` block toggles to active-active when secondary_region is
# non-empty. PAY_PER_REQUEST keeps the workload bursty-shape friendly; stream
# enabled for V2 archival hooks.
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

  server_side_encryption {
    enabled = true
  }

  dynamic "replica" {
    for_each = var.secondary_region != "" ? [var.secondary_region] : []
    content {
      region_name            = replica.value
      point_in_time_recovery = true
    }
  }

  tags = { Name = "aegis-enclave-executions" }
}

# ─── Container registry (ECR with scan-on-push + immutable tags) ───────────
module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "2.4.0" # exact pin (case-study reproducibility); was ~> 2.3

  repository_name                 = "aegis-enclave"
  repository_image_tag_mutability = "IMMUTABLE"
  repository_image_scan_on_push   = true # DevSecOps signal — scan on push

  repository_lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain last 10 images; expire older"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ─── Internal ALB self-signed TLS certificate (ADR-0027) ──────────────────
# The internal ALB terminates TLS so the operator's curl uses https:// — same
# protocol as a production deployment, even though the encrypted boundary at
# this scope is the Client VPN tunnel and the ALB is private-only. Self-signed
# (not ACM-issued from a public CA) because the hostname `api.enclave.internal`
# is internal-only and not in any public DNS zone we own; ACM Private CA is
# $400/mo overkill for a 3-hour acceptance window. Imported into ACM as a
# regular ACM certificate — no charge for imports, only for ACM Private CA.
resource "tls_private_key" "alb" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  private_key_pem = tls_private_key.alb.private_key_pem

  subject {
    common_name  = var.alb_internal_hostname
    organization = "aegis-enclave"
  }

  validity_period_hours = 8760 # one year — far past any realistic acceptance window

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]

  dns_names = [var.alb_internal_hostname]
}

resource "aws_acm_certificate" "alb" {
  private_key      = tls_private_key.alb.private_key_pem
  certificate_body = tls_self_signed_cert.alb.cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Internal load balancer (private, behind Client VPN endpoint) ──────────
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.17.0" # exact pin (case-study reproducibility); was ~> 9.9

  name    = "aegis-enclave-alb"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  internal           = true # not internet-facing — only VPN-reachable
  load_balancer_type = "application"

  # Case-study cloud-acceptance window = bounded apply-then-destroy (per
  # ADR-0034). Production deployments should override to true; the community
  # alb module defaults to true (safe), but blocks `terraform destroy` for
  # the bounded acceptance window.
  enable_deletion_protection = false

  # Three-layer timeout defence (ADR-0020): app wait_for is 30s + 10s, ALB
  # sits at 45s so the client sees the application's 504 response rather
  # than a connection reset from ALB.
  idle_timeout = 45

  security_groups = [module.alb_sg.security_group_id]

  # ADR-0027 — HTTPS-only listener, self-signed cert imported to ACM.
  listeners = {
    https = {
      port            = 443
      protocol        = "HTTPS"
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      certificate_arn = aws_acm_certificate.alb.arn
      forward = {
        target_group_key = "app"
      }
    }
  }

  target_groups = {
    app = {
      name_prefix = "app-"
      protocol    = "HTTP"
      port        = 8000
      target_type = "ip"

      # ECS service registers targets dynamically (load_balancer block in
      # module.ecs.services["app"]). Without this, alb >=9.x tries to create
      # a static target group attachment per target_groups entry and demands
      # an each.value.target_id field — which doesn't apply when ECS owns
      # the target lifecycle.
      create_attachment = false

      # ADR-0033 — Drain semantics (API tier). Default 300s drains existing
      # connections for 5 minutes after deregister, which is wildly long for
      # this scope (and means rolling deploys block on the slowest in-flight
      # request for 5 minutes). 60s matches the longest legitimate compute
      # path (30s prime budget + 10s audit + slack).
      deregistration_delay = 60

      health_check = {
        path                = "/health"
        healthy_threshold   = 2
        unhealthy_threshold = 3
        interval            = 30
        timeout             = 5
      }
    }
  }
}

# ─── Compute (ADR-0015: ECS Fargate over EKS — no K8s control-plane fee) ───
module "ecs" {
  source = "terraform-aws-modules/ecs/aws"
  # Pinned to 5.11.x explicitly: 5.12.x introduced a regression in
  # modules/service/main.tf where 'for_each = {... : k => v if try(v.create, true)}'
  # over container_definitions returns unknown when any inner value (image,
  # secrets) references another module's output. for_each then errors with
  # 'var.container_definitions will be known only after apply'.
  # See https://github.com/terraform-aws-modules/terraform-aws-ecs/issues
  # 5.11.x predates that change and accepts our standard module-output references.
  # Exact-pinned to 5.11.4 (case-study reproducibility) — registry could otherwise
  # tag 5.11.5 with a regression and silently break the next forker apply.
  version = "5.11.4"

  cluster_name = "aegis-enclave"

  cluster_configuration = {
    execute_command_configuration = {
      # ECS module 5.11.x auto-adds a log_configuration block when
      # containerInsights is enabled. AWS API requires logging = "OVERRIDE"
      # whenever log_configuration is present (DEFAULT only valid when no
      # log_configuration). Without this, CreateCluster fails with
      # InvalidParameterException: "You must set logging to 'OVERRIDE'
      # when you supply a log configuration."
      logging = "OVERRIDE"
      log_configuration = {
        cloud_watch_log_group_name = "/aws/ecs/aegis-enclave"
      }
    }
  }

  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 100
        base   = 1
      }
    }
  }

  services = {
    app = {
      cpu    = 256
      memory = 512

      # ADR-0007 reconsidered (04/28): app starts at 3 tasks, one per AZ.
      # ECS Fargate spreads tasks across the 3 private subnets via the
      # subnet_ids list below, so AZ loss leaves 2/3 capacity (vs 1/2 with
      # the prior 2-AZ posture). Worker autoscale separately governs worker
      # task count via SQS depth (see aws_appautoscaling_target.worker).
      desired_count = 3

      container_definitions = {
        app = {
          image = "${module.ecr.repository_url}:${var.image_tag}"
          port_mappings = [{
            containerPort = 8000
            protocol      = "tcp"
          }]
          # ADR-0042: app talks to DynamoDB via boto3. AWS_DEFAULT_REGION
          # tells the SDK which region's endpoint to use; DYNAMODB_TABLE_NAME
          # names the executions table. No POSTGRES_* vars (RDS removed).
          environment = [
            { name = "DYNAMODB_TABLE_NAME", value = aws_dynamodb_table.executions.name },
            { name = "AWS_DEFAULT_REGION", value = var.region },
          ]
          # No secrets — DDB authn is IAM, not Secrets Manager.

          # ADR-0033 — Drain semantics (API tier). ECS sends SIGTERM, waits
          # stop_timeout, then SIGKILL. Set to 60s so it strictly exceeds
          # uvicorn's `--timeout-graceful-shutdown 45` (Dockerfile) — a
          # request that started just before SIGTERM still has 45s to finish
          # before uvicorn drops it, and ECS waits another 15s before SIGKILL.
          stop_timeout = 60

          # Explicit log_configuration mirroring worker / bootstrap pattern.
          # Without this, terraform-aws-modules/ecs auto-creates a log group
          # with retention_in_days=null (never-expire) — a slow cost leak for
          # forkers running long-term. 7-day retention matches our other
          # task definitions and the case-study cycle window.
          logConfiguration = {
            logDriver = "awslogs"
            options = {
              "awslogs-group"         = "/ecs/aegis-enclave-app"
              "awslogs-region"        = var.region
              "awslogs-stream-prefix" = "app"
            }
          }

          readonly_root_filesystem = false # FastAPI/uvicorn writes to tmpdir
          essential                = true
        }
      }

      # Disable the module's auto-created log group so our explicit one above
      # is the canonical destination (avoids drift between two log groups for
      # the same service).
      create_cloudwatch_log_group = false

      load_balancer = {
        service = {
          target_group_arn = module.alb.target_groups["app"].arn
          container_name   = "app"
          container_port   = 8000
        }
      }

      subnet_ids         = module.vpc.private_subnets
      security_group_ids = [module.app_sg.security_group_id]

      # App POSTs enqueue jobs to the primes queue. Worker has receive/delete
      # perms (worker_inline policy) but app needs SendMessage. App also
      # writes `queued` rows to DDB on POST. The community ecs/service module
      # auto-creates the tasks IAM role; we extend it via
      # tasks_iam_role_statements rather than detaching/recreating.
      tasks_iam_role_statements = {
        sqs_enqueue = {
          actions = [
            "sqs:SendMessage",
            "sqs:GetQueueUrl",
            "sqs:GetQueueAttributes",
          ]
          resources = [aws_sqs_queue.primes.arn]
        }
        # ADR-0042: app writes queued rows + reads on poll. Worker IAM policy
        # below grants the same on its own role; this block scopes the app's
        # inline tasks-role to the executions table only.
        dynamodb_executions = {
          actions = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:Query",
            "dynamodb:DescribeTable",
          ]
          resources = [aws_dynamodb_table.executions.arn]
        }
      }
    }
  }
}

# ─── VPN (ADR-0006: AWS Client VPN endpoint primary, NetBird alternative) ──
resource "aws_ec2_client_vpn_endpoint" "main" {
  description            = "aegis-enclave Client VPN - operator + ground-station access"
  server_certificate_arn = var.server_cert_arn
  client_cidr_block      = "10.20.0.0/16" # avoid VPC CIDR overlap

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.client_cert_arn
  }

  connection_log_options {
    enabled = false # case-study scope; production logs to CloudWatch
  }

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [module.alb_sg.security_group_id] # initial association

  split_tunnel = true
  dns_servers  = []
}

resource "aws_ec2_client_vpn_network_association" "primary_az" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.main.id
  subnet_id              = module.vpc.private_subnets[0]
}

resource "aws_ec2_client_vpn_network_association" "secondary_az" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.main.id
  subnet_id              = module.vpc.private_subnets[1]
}

resource "aws_ec2_client_vpn_network_association" "tertiary_az" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.main.id
  subnet_id              = module.vpc.private_subnets[2]
}

resource "aws_ec2_client_vpn_authorization_rule" "vpc_access" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.main.id
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
  description            = "Authorize VPN clients to reach VPC services"
}

# ─── Async job queue (SQS) — per ADR-0029 ────────────────────────────────────
# Queue for prime-computation jobs. Visibility timeout = compute_budget × 1.5
# so a message re-delivers if the worker crashes without acking.

resource "aws_sqs_queue" "primes_dlq" {
  name                      = "aegis-enclave-primes-dlq"
  message_retention_seconds = 1209600 # 14 days — max; keeps failed messages for analysis
  receive_wait_time_seconds = 0
}

# ─── Alerting backbone — conditional SNS topic for email delivery ─────────
# ADR-0041: alarms always exist + always emit state changes to EventBridge
# (audit trail). Email delivery is opt-in via var.alarm_email — empty string
# (default) leaves alarm_actions = [] and the deliverable ships with no
# unsolicited mail to a forker. Setting alarm_email via tfvars-init prompt
# (or TF_ALARM_EMAIL env var) provisions an SNS topic + email subscription
# and wires every alarm below to it.
resource "aws_sns_topic" "alarms" {
  count = var.alarm_email != "" ? 1 : 0
  name  = "aegis-enclave-alarms"
}

resource "aws_sns_topic_subscription" "alarms_email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# Helper local — every alarm references this for alarm_actions / ok_actions.
locals {
  alarm_action_list = try([aws_sns_topic.alarms[0].arn], [])
}

# ─── DLQ depth alarm — operator-actionable signal (ADR-0038) ──────────────
resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "aegis-enclave-primes-dlq-depth"
  alarm_description   = "DLQ has at least one message - worker exhausted maxReceiveCount=3 retries on main queue. Triage with scripts/dlq-triage.sh per ADR-0038."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60 # 1-minute granularity
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching" # zero-depth = OK, missing data = OK

  dimensions = {
    QueueName = aws_sqs_queue.primes_dlq.name
  }

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# ─── SLO alarms (ADR-0041) ────────────────────────────────────────────────
# SLI metrics emitted via EMF from src/prime_service/{main,worker,metrics}.py
# into the "aegis-enclave" CloudWatch namespace.

# Multi-window multi-burn-rate (Google SRE Workbook canonical pattern):
# Fast burn — 1h window, 14.4× SLO threshold (consumes 2% of 30-day budget in 1h).
resource "aws_cloudwatch_metric_alarm" "slo_fast_burn" {
  alarm_name          = "aegis-enclave-slo-fast-burn"
  alarm_description   = "SLO fast burn: 5xx error rate > 1.44% over 1h (14.4x the 0.1% target). Consumes 2% of 30-day error budget if sustained."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1.44
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate_pct"
    expression  = "100 * (FILL(m_errors, 0) / m_total)"
    label       = "5xx error rate %"
    return_data = true
  }
  metric_query {
    id = "m_errors"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "request_errors_5xx"
      period      = 3600
      stat        = "Sum"
    }
  }
  metric_query {
    id = "m_total"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "request_total"
      period      = 3600
      stat        = "Sum"
    }
  }

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# Slow burn — 6h window, 6× SLO threshold (consumes 5% of budget in 6h).
resource "aws_cloudwatch_metric_alarm" "slo_slow_burn" {
  alarm_name          = "aegis-enclave-slo-slow-burn"
  alarm_description   = "SLO slow burn: 5xx error rate > 0.6% over 6h (6x the 0.1% target). Consumes 5% of 30-day error budget if sustained."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0.6
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate_pct"
    expression  = "100 * (FILL(m_errors, 0) / m_total)"
    label       = "5xx error rate %"
    return_data = true
  }
  metric_query {
    id = "m_errors"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "request_errors_5xx"
      period      = 21600 # 6h
      stat        = "Sum"
    }
  }
  metric_query {
    id = "m_total"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "request_total"
      period      = 21600
      stat        = "Sum"
    }
  }

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# Composite — only page when BOTH fast AND slow burn fire.
resource "aws_cloudwatch_composite_alarm" "slo_breach" {
  alarm_name        = "aegis-enclave-slo-breach"
  alarm_description = "Confirmed SLO breach: fast-burn AND slow-burn both ALARM. Real error budget consumption past 7%; operator action expected."
  alarm_rule        = "ALARM(${aws_cloudwatch_metric_alarm.slo_fast_burn.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.slo_slow_burn.alarm_name})"

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# Latency SLO — POST 202 should return < 500ms p99.
resource "aws_cloudwatch_metric_alarm" "latency_p99_breach" {
  alarm_name          = "aegis-enclave-latency-p99-breach"
  alarm_description   = "API request latency p99 > 500ms sustained for 15 minutes. Per ADR-0008 SLO."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3 # 3 x 5min periods -> 15min sustained
  threshold           = 500
  treat_missing_data  = "notBreaching"

  metric_name        = "request_latency_ms"
  namespace          = "aegis-enclave"
  period             = 300
  extended_statistic = "p99"

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# Cache hit ratio SLO — degraded cache effectiveness signals upstream issue.
resource "aws_cloudwatch_metric_alarm" "cache_hit_ratio_low" {
  alarm_name          = "aegis-enclave-cache-hit-ratio-low"
  alarm_description   = "Cache hit ratio < 80% over 30min sustained. Suggests Valkey unhealthy, bootstrap didn't seed, or range-coalescing broken."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = 80
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "hit_ratio_pct"
    expression  = "100 * (FILL(m_hit, 0) / (FILL(m_hit, 0) + FILL(m_miss, 0)))"
    label       = "cache hit ratio %"
    return_data = true
  }
  metric_query {
    id = "m_hit"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "cache_hit_count"
      period      = 1800
      stat        = "Sum"
    }
  }
  metric_query {
    id = "m_miss"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "cache_miss_count"
      period      = 1800
      stat        = "Sum"
    }
  }

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# SLO dashboard — single-pane visualization.
resource "aws_cloudwatch_dashboard" "slo" {
  dashboard_name = "aegis-enclave-slo"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title = "Request volume + cache breakdown"
          metrics = [
            ["aegis-enclave", "request_total", { stat = "Sum", label = "Total requests" }],
            [".", "cache_hit_count", { stat = "Sum", label = "Cache hits" }],
            [".", "cache_miss_count", { stat = "Sum", label = "Cache misses" }],
          ]
          period  = 60
          region  = var.region
          view    = "timeSeries"
          stacked = false
          yAxis   = { left = { min = 0, label = "requests / minute" } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title = "API request latency (SLO target: p99 < 500ms)"
          metrics = [
            ["aegis-enclave", "request_latency_ms", { stat = "p50", label = "p50" }],
            [".", ".", { stat = "p95", label = "p95" }],
            [".", ".", { stat = "p99", label = "p99" }],
          ]
          period = 60
          region = var.region
          view   = "timeSeries"
          yAxis  = { left = { min = 0, label = "ms" } }
          annotations = {
            horizontal = [
              { value = 500, label = "SLO p99 target", color = "#d62728" },
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "5xx error rate % (SLO target < 0.1%)"
          metrics = [
            [
              {
                expression = "100 * (FILL(m_errors, 0) / m_total)"
                label      = "5xx error rate %"
                id         = "rate"
              }
            ],
            ["aegis-enclave", "request_errors_5xx", { id = "m_errors", visible = false, stat = "Sum" }],
            [".", "request_total", { id = "m_total", visible = false, stat = "Sum" }],
          ]
          period = 60
          region = var.region
          view   = "timeSeries"
          yAxis  = { left = { min = 0, label = "% errors" } }
          annotations = {
            horizontal = [
              { value = 0.1, label = "SLO target 0.1%", color = "#2ca02c" },
              { value = 0.6, label = "Slow-burn threshold (6x SLO, 6h window)", color = "#ff7f0e" },
              { value = 1.44, label = "Fast-burn threshold (14.4x SLO, 1h window)", color = "#d62728" },
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Cache hit ratio % (SLO target >= 80%)"
          metrics = [
            [
              {
                expression = "100 * (FILL(m_hit, 0) / (FILL(m_hit, 0) + FILL(m_miss, 0)))"
                label      = "cache hit ratio %"
                id         = "ratio"
              }
            ],
            ["aegis-enclave", "cache_hit_count", { id = "m_hit", visible = false, stat = "Sum" }],
            [".", "cache_miss_count", { id = "m_miss", visible = false, stat = "Sum" }],
          ]
          period = 60
          region = var.region
          view   = "timeSeries"
          yAxis  = { left = { min = 0, max = 100, label = "% hit" } }
          annotations = {
            horizontal = [
              { value = 80, label = "SLO target 80%", color = "#2ca02c" },
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "Worker compute duration (SIGALRM ceiling 60000ms)"
          metrics = [
            ["aegis-enclave", "compute_duration_ms", { stat = "p50", label = "p50" }],
            [".", ".", { stat = "p95", label = "p95" }],
            [".", ".", { stat = "p99", label = "p99" }],
          ]
          period = 60
          region = var.region
          view   = "timeSeries"
          yAxis  = { left = { min = 0, label = "ms" } }
          annotations = {
            horizontal = [
              { value = 30000, label = "SLO target p95 < 30s", color = "#ff7f0e" },
              { value = 60000, label = "SIGALRM hard ceiling", color = "#d62728" },
            ]
          }
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "SLO alarm states"
          alarms = [
            aws_cloudwatch_metric_alarm.slo_fast_burn.arn,
            aws_cloudwatch_metric_alarm.slo_slow_burn.arn,
            aws_cloudwatch_composite_alarm.slo_breach.arn,
            aws_cloudwatch_metric_alarm.latency_p99_breach.arn,
            aws_cloudwatch_metric_alarm.cache_hit_ratio_low.arn,
            aws_cloudwatch_metric_alarm.compute_p95_breach.arn,
            aws_cloudwatch_metric_alarm.dlq_depth.arn,
          ]
        }
      },
    ]
  })
}

# Compute path latency SLO.
resource "aws_cloudwatch_metric_alarm" "compute_p95_breach" {
  alarm_name          = "aegis-enclave-compute-p95-breach"
  alarm_description   = "Worker compute_duration_ms p95 > 30s sustained 15min. Half the SIGALRM 60s ceiling - investigate range distribution + CPU."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 30000
  treat_missing_data  = "notBreaching"

  metric_name        = "compute_duration_ms"
  namespace          = "aegis-enclave"
  period             = 300
  extended_statistic = "p95"

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

resource "aws_sqs_queue" "primes" {
  name                       = "aegis-enclave-primes"
  visibility_timeout_seconds = var.sqs_visibility_timeout
  message_retention_seconds  = 86400 # 1 day
  receive_wait_time_seconds  = 20    # long-polling — reduces empty receive costs

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.primes_dlq.arn
    maxReceiveCount     = 3
  })
}

# ─── Distributed cache (ElastiCache Serverless Valkey) — per ADR-0031 ───────

resource "aws_security_group" "valkey" {
  name        = "aegis-enclave-valkey-sg"
  description = "ElastiCache Serverless Valkey - accept inbound 6379 from ECS tasks only"
  vpc_id      = module.vpc.vpc_id

  # Egress: unrestricted (required for cluster-mode inter-node traffic internal to ElastiCache)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Unrestricted egress - ElastiCache Serverless requirement"
  }

  tags = { Name = "aegis-enclave-valkey-sg" }
}

# Allow the app ECS tasks to reach Valkey.
resource "aws_security_group_rule" "app_to_valkey" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  description              = "App ECS task to Valkey 6379"
  security_group_id        = aws_security_group.valkey.id
  source_security_group_id = module.app_sg.security_group_id
}

# Allow the worker ECS tasks to reach Valkey.
resource "aws_security_group_rule" "worker_to_valkey" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  description              = "Worker ECS task to Valkey 6379"
  security_group_id        = aws_security_group.valkey.id
  source_security_group_id = aws_security_group.worker.id
}

# Note: bootstrap_to_valkey rule removed - cache_bootstrap ECS task uses
# aws_security_group.worker (same SG as worker), so worker_to_valkey already
# authorises bootstrap traffic.
#
# Note (ADR-0042): worker_to_rds rule removed — RDS module deleted; DDB is
# accessed via the gateway VPC endpoint, no SG rule needed (DDB endpoint is
# reachable through the route table, not SG-attached ENIs).

resource "aws_elasticache_serverless_cache" "valkey" {
  engine = "valkey"
  name   = "aegis-enclave-valkey"

  cache_usage_limits {
    data_storage {
      maximum = var.valkey_max_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.valkey_max_ecpu_per_sec
    }
  }

  # No snapshots — cost guard + privacy (no residual data after destroy).
  snapshot_retention_limit = 0

  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [aws_security_group.valkey.id]
}

# ─── IAM role for the worker ECS task (ADR-0042: DDB perms, not RDS) ───────
# Permissions needed by the worker and bootstrap containers:
#   - SQS: receive, delete, get-queue-attributes (worker poll + ack + depth)
#   - Valkey: no IAM — authenticated by network isolation (SG) only
#   - DynamoDB: GetItem / PutItem / UpdateItem / Query / DescribeTable
#     scoped to the executions table (single-table model per ADR-0042)
#   - ECR + logs: standard Fargate task role attachments

data "aws_iam_policy_document" "worker_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "worker" {
  name               = "aegis-enclave-worker"
  assume_role_policy = data.aws_iam_policy_document.worker_assume.json
}

data "aws_iam_policy_document" "worker_policy" {
  # SQS: receive + ack + depth-check on the primes queue.
  statement {
    sid = "SQSPrimes"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [
      aws_sqs_queue.primes.arn,
      aws_sqs_queue.primes_dlq.arn,
    ]
  }

  # ADR-0042: DynamoDB executions table — read + write + describe.
  # Scoped to the table ARN (and its index ARNs via /index/* glob — none
  # provisioned in v1, glob covers future GSI extension without policy churn).
  statement {
    sid = "DynamoDBExecutions"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:DescribeTable",
    ]
    resources = [
      aws_dynamodb_table.executions.arn,
      "${aws_dynamodb_table.executions.arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "worker_inline" {
  name   = "aegis-enclave-worker-inline"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker_policy.json
}

# Standard Fargate managed policies (ECR pull + CloudWatch logs).
resource "aws_iam_role_policy_attachment" "worker_ecr" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "worker_logs" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

# ─── Security group for the worker ECS service ───────────────────────────────

resource "aws_security_group" "worker" {
  name        = "aegis-enclave-worker-sg"
  description = "Worker ECS task - egress to SQS VPC endpoint, Valkey, DDB, ECR"
  vpc_id      = module.vpc.vpc_id

  # No ingress - worker only pulls from SQS, never receives inbound traffic.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Unrestricted egress - worker reaches SQS endpoint, Valkey, DDB, ECR via VPC endpoints"
  }

  tags = { Name = "aegis-enclave-worker-sg" }
}

# ─── ECS task definition: worker (ADR-0042 env vars: DDB, no POSTGRES_*) ─────

resource "aws_ecs_task_definition" "worker" {
  family                   = "aegis-enclave-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512  # 0.5 vCPU — compute-bound sieve needs more than app
  memory                   = 1024 # 1 GB — headroom for sieve memory at range ceiling

  task_role_arn      = aws_iam_role.worker.arn
  execution_role_arn = aws_iam_role.worker.arn

  container_definitions = jsonencode([{
    name  = "worker"
    image = "${module.ecr.repository_url}:${var.image_tag}"

    # Override the Dockerfile CMD to start the worker consumer loop.
    command = ["python", "-m", "prime_service.worker"]

    # SIGTERM grace: 65s — exceeds the 60s SIGALRM compute budget so an
    # in-flight sieve has time to finish (or timeout) before ECS SIGKILLs.
    stopTimeout = 65

    # ADR-0042: DDB env vars replace POSTGRES_*. AWS SDK reads
    # AWS_DEFAULT_REGION; DYNAMODB_TABLE_NAME points the worker at the
    # executions table (single-table model).
    environment = [
      { name = "DYNAMODB_TABLE_NAME", value = aws_dynamodb_table.executions.name },
      { name = "AWS_DEFAULT_REGION", value = var.region },
      { name = "VALKEY_ENDPOINT", value = "${aws_elasticache_serverless_cache.valkey.endpoint[0].address}:${aws_elasticache_serverless_cache.valkey.endpoint[0].port}" },
      { name = "VALKEY_TLS", value = "true" },
    ]

    # No secrets block — DDB authn is IAM, no DB password to fetch.

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/aegis-enclave-worker"
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "worker"
      }
    }

    essential              = true
    readonlyRootFilesystem = false
  }])
}

# CloudWatch log group for the worker.
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/aegis-enclave-worker"
  retention_in_days = 7
}

# CloudWatch log group for the FastAPI app container.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/aegis-enclave-app"
  retention_in_days = 7
}

# ─── ECS task definition: cache_bootstrap (ADR-0042 env vars) ────────────────
# One-shot task — triggered by null_resource after Valkey is ready.
# 256 CPU / 512 MB — bootstrap just runs a sieve + single Redis write.
# Bootstrap scope is cache pre-warm only — DDB tables are terraform-managed
# (no schema migration step needed in the greenfield path per ADR-0042).

resource "aws_ecs_task_definition" "cache_bootstrap" {
  family                   = "aegis-enclave-cache-bootstrap"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  task_role_arn      = aws_iam_role.worker.arn
  execution_role_arn = aws_iam_role.worker.arn

  container_definitions = jsonencode([{
    name    = "bootstrap"
    image   = "${module.ecr.repository_url}:${var.image_tag}"
    command = ["python", "-m", "prime_service.bootstrap"]

    environment = [
      { name = "DYNAMODB_TABLE_NAME", value = aws_dynamodb_table.executions.name },
      { name = "AWS_DEFAULT_REGION", value = var.region },
      { name = "VALKEY_ENDPOINT", value = "${aws_elasticache_serverless_cache.valkey.endpoint[0].address}:${aws_elasticache_serverless_cache.valkey.endpoint[0].port}" },
      { name = "VALKEY_TLS", value = "true" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/aegis-enclave-bootstrap"
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "bootstrap"
      }
    }

    essential              = true
    readonlyRootFilesystem = false
  }])
}

# CloudWatch log group for the bootstrap task.
resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/ecs/aegis-enclave-bootstrap"
  retention_in_days = 7
}

# ─── ECS service: worker ─────────────────────────────────────────────────────

resource "aws_ecs_service" "worker" {
  name            = "aegis-enclave-worker"
  cluster         = module.ecs.cluster_id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_min_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_ecr,
    aws_iam_role_policy_attachment.worker_logs,
  ]
}

# ─── ECS autoscaling: worker on SQS queue depth ──────────────────────────────

resource "aws_appautoscaling_target" "worker" {
  max_capacity       = var.worker_max_count
  min_capacity       = var.worker_min_count
  resource_id        = "service/${module.ecs.cluster_name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.worker]
}

resource "aws_appautoscaling_policy" "target_tracking" {
  name               = "aegis-enclave-worker-sqs-depth"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension
  service_namespace  = aws_appautoscaling_target.worker.service_namespace

  target_tracking_scaling_policy_configuration {
    customized_metric_specification {
      metric_name = "ApproximateNumberOfMessagesVisible"
      namespace   = "AWS/SQS"
      statistic   = "Sum"

      dimensions {
        name  = "QueueName"
        value = aws_sqs_queue.primes.name
      }
    }

    target_value       = var.backpressure_threshold_factor
    scale_in_cooldown  = 300 # 5 min — conservative scale-in to avoid flapping
    scale_out_cooldown = 60  # 1 min — aggressive scale-out when queue builds up
  }
}

# ─── Bootstrap one-shot (null_resource local-exec) ───────────────────────────

resource "null_resource" "run_cache_bootstrap" {
  triggers = {
    # Re-run if the task definition revision changes (e.g. new image).
    task_definition_arn = aws_ecs_task_definition.cache_bootstrap.arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws ecs run-task \
        --cluster "${module.ecs.cluster_name}" \
        --task-definition "${aws_ecs_task_definition.cache_bootstrap.arn}" \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[${join(",", module.vpc.private_subnets)}],securityGroups=[${aws_security_group.worker.id}],assignPublicIp=DISABLED}" \
        --region "${var.region}"
    EOT
  }

  depends_on = [
    aws_elasticache_serverless_cache.valkey,
    aws_ecs_task_definition.cache_bootstrap,
  ]
}

# ═══════════════════════════════════════════════════════════════════════════
# SECONDARY REGION (ADR-0042 multi-region active-active mirror)
# ═══════════════════════════════════════════════════════════════════════════
# All resources below are conditional on `local.is_multi_region`. Each mirrors
# its primary-region counterpart with `provider = aws.secondary`. The DDB
# table itself is single-resource with replica config (above); compute / VPC /
# ALB / Valkey / SQS / Client VPN are mirrored per-region (active-active).
#
# DESIGN NOTES:
# - Resources use `count = local.is_multi_region` so single-region scope leaves
#   them un-provisioned and terraform plan output is clean.
# - VPC CIDR comes from var.secondary_vpc_cidr (default 10.10.0.0/16) to
#   avoid any future inter-region peering CIDR overlap.
# - Each region has its own VPN endpoint + cert pair; the forker provides
#   var.secondary_server_cert_arn + var.secondary_client_cert_arn (typically
#   from a separate scripts/bootstrap-vpn-certs.sh --region $secondary run).
# - VPC endpoints + Valkey + SQS + IAM are mirrored to keep the deployment
#   active-active rather than active-passive (ADR-0042 § Why active-active).
# - To keep main.tf legible, the secondary mirror uses inline aws_vpc resources
#   rather than a second module.vpc instantiation (community modules don't
#   propagate aliased provider configs cleanly with count).

# ─── Secondary VPC (3 private subnets, no public, no NAT) ──────────────────
resource "aws_vpc" "secondary" {
  count    = local.is_multi_region
  provider = aws.secondary

  cidr_block           = var.secondary_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "aegis-enclave-vpc-secondary" }
}

resource "aws_subnet" "secondary_private" {
  count    = local.is_multi_region * 3 # 3 AZs
  provider = aws.secondary

  vpc_id            = aws_vpc.secondary[0].id
  cidr_block        = cidrsubnet(var.secondary_vpc_cidr, 8, count.index + 1)
  availability_zone = "${var.secondary_region}${["a", "b", "c"][count.index]}"

  tags = { Name = "aegis-enclave-secondary-private-${count.index}" }
}

resource "aws_route_table" "secondary_private" {
  count    = local.is_multi_region
  provider = aws.secondary

  vpc_id = aws_vpc.secondary[0].id

  tags = { Name = "aegis-enclave-secondary-private-rt" }
}

resource "aws_route_table_association" "secondary_private" {
  count    = local.is_multi_region * 3
  provider = aws.secondary

  subnet_id      = aws_subnet.secondary_private[count.index].id
  route_table_id = aws_route_table.secondary_private[0].id
}

# ─── Secondary VPC Endpoints ───────────────────────────────────────────────
resource "aws_security_group" "secondary_vpc_endpoints" {
  count    = local.is_multi_region
  provider = aws.secondary

  name        = "aegis-enclave-secondary-vpc-endpoints-sg"
  description = "Secondary region VPC Endpoint ENI inbound - HTTPS from VPC"
  vpc_id      = aws_vpc.secondary[0].id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.secondary_vpc_cidr]
    description = "HTTPS from secondary VPC CIDR"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All egress"
  }

  tags = { Name = "aegis-enclave-secondary-vpc-endpoints-sg" }
}

resource "aws_vpc_endpoint" "secondary_s3" {
  count    = local.is_multi_region
  provider = aws.secondary

  vpc_id            = aws_vpc.secondary[0].id
  service_name      = "com.amazonaws.${var.secondary_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.secondary_private[0].id]

  tags = { Name = "aegis-enclave-secondary-s3-gateway" }
}

resource "aws_vpc_endpoint" "secondary_dynamodb" {
  count    = local.is_multi_region
  provider = aws.secondary

  vpc_id            = aws_vpc.secondary[0].id
  service_name      = "com.amazonaws.${var.secondary_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.secondary_private[0].id]

  tags = { Name = "aegis-enclave-secondary-dynamodb-gateway" }
}

# Interface endpoints — same set as primary. Use a separate locals block here
# since the primary `local.interface_endpoints` is reused.
resource "aws_vpc_endpoint" "secondary_interfaces" {
  for_each = local.is_multi_region == 1 ? local.interface_endpoints : toset([])
  provider = aws.secondary

  vpc_id              = aws_vpc.secondary[0].id
  service_name        = "com.amazonaws.${var.secondary_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.secondary_private[*].id
  security_group_ids  = [aws_security_group.secondary_vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = { Name = "aegis-enclave-secondary-${replace(each.value, ".", "-")}" }
}

# ─── Secondary Security groups ─────────────────────────────────────────────
resource "aws_security_group" "secondary_alb" {
  count    = local.is_multi_region
  provider = aws.secondary

  name        = "aegis-enclave-secondary-alb-sg"
  description = "Secondary internal ALB - reachable only from secondary VPC"
  vpc_id      = aws_vpc.secondary[0].id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.secondary_vpc_cidr]
    description = "HTTPS-443-tcp from secondary VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All egress"
  }

  tags = { Name = "aegis-enclave-secondary-alb-sg" }
}

resource "aws_security_group" "secondary_app" {
  count    = local.is_multi_region
  provider = aws.secondary

  name        = "aegis-enclave-secondary-app-sg"
  description = "Secondary app ECS task - accept traffic only from secondary ALB"
  vpc_id      = aws_vpc.secondary[0].id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    description     = "App port from secondary ALB"
    security_groups = [aws_security_group.secondary_alb[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All egress"
  }

  tags = { Name = "aegis-enclave-secondary-app-sg" }
}

resource "aws_security_group" "secondary_worker" {
  count    = local.is_multi_region
  provider = aws.secondary

  name        = "aegis-enclave-secondary-worker-sg"
  description = "Secondary worker ECS task - egress to SQS endpoint, Valkey, DDB, ECR"
  vpc_id      = aws_vpc.secondary[0].id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Unrestricted egress"
  }

  tags = { Name = "aegis-enclave-secondary-worker-sg" }
}

resource "aws_security_group" "secondary_valkey" {
  count    = local.is_multi_region
  provider = aws.secondary

  name        = "aegis-enclave-secondary-valkey-sg"
  description = "Secondary ElastiCache Serverless Valkey - inbound 6379 from ECS tasks"
  vpc_id      = aws_vpc.secondary[0].id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.secondary_app[0].id, aws_security_group.secondary_worker[0].id]
    description     = "App + Worker ECS tasks to Valkey 6379"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Unrestricted egress - ElastiCache Serverless requirement"
  }

  tags = { Name = "aegis-enclave-secondary-valkey-sg" }
}

# ─── Secondary internal ALB self-signed cert (per ADR-0027, 1 per region) ──
resource "tls_private_key" "secondary_alb" {
  count = local.is_multi_region

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "secondary_alb" {
  count = local.is_multi_region

  private_key_pem = tls_private_key.secondary_alb[0].private_key_pem

  subject {
    common_name  = var.alb_internal_hostname
    organization = "aegis-enclave"
  }

  validity_period_hours = 8760

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]

  dns_names = [var.alb_internal_hostname]
}

resource "aws_acm_certificate" "secondary_alb" {
  count    = local.is_multi_region
  provider = aws.secondary

  private_key      = tls_private_key.secondary_alb[0].private_key_pem
  certificate_body = tls_self_signed_cert.secondary_alb[0].cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Secondary internal ALB + listener + target group (inline, not module) ─
resource "aws_lb" "secondary" {
  count    = local.is_multi_region
  provider = aws.secondary

  name               = "aegis-enclave-secondary-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.secondary_alb[0].id]
  subnets            = aws_subnet.secondary_private[*].id

  enable_deletion_protection = false
  idle_timeout               = 45

  tags = { Name = "aegis-enclave-secondary-alb" }
}

resource "aws_lb_target_group" "secondary_app" {
  count    = local.is_multi_region
  provider = aws.secondary

  name_prefix = "app-"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.secondary[0].id

  deregistration_delay = 60

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "secondary_https" {
  count    = local.is_multi_region
  provider = aws.secondary

  load_balancer_arn = aws_lb.secondary[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.secondary_alb[0].arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.secondary_app[0].arn
  }
}

# ─── Secondary ECR — separate per region (ECR is regional service) ─────────
resource "aws_ecr_repository" "secondary" {
  count    = local.is_multi_region
  provider = aws.secondary

  name                 = "aegis-enclave"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "secondary" {
  count    = local.is_multi_region
  provider = aws.secondary

  repository = aws_ecr_repository.secondary[0].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain last 10 images; expire older"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ─── Secondary ECS cluster + log groups ────────────────────────────────────
resource "aws_ecs_cluster" "secondary" {
  count    = local.is_multi_region
  provider = aws.secondary

  name = "aegis-enclave-secondary"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "secondary_app" {
  count    = local.is_multi_region
  provider = aws.secondary

  name              = "/ecs/aegis-enclave-secondary-app"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "secondary_worker" {
  count    = local.is_multi_region
  provider = aws.secondary

  name              = "/ecs/aegis-enclave-secondary-worker"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "secondary_bootstrap" {
  count    = local.is_multi_region
  provider = aws.secondary

  name              = "/ecs/aegis-enclave-secondary-bootstrap"
  retention_in_days = 7
}

# ─── Secondary IAM role for ECS tasks (mirrors primary worker role) ─────────
data "aws_iam_policy_document" "secondary_worker_assume" {
  count = local.is_multi_region

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "secondary_worker" {
  count    = local.is_multi_region
  provider = aws.secondary

  name               = "aegis-enclave-secondary-worker"
  assume_role_policy = data.aws_iam_policy_document.secondary_worker_assume[0].json
}

# IAM policy for secondary tasks. DDB table ARN is from the primary-region
# resource (DynamoDB is global; the table ARN is the same regardless of which
# region the call originates from), but we add the secondary-region replica
# ARN form for cross-region IAM completeness. Replica ARNs follow the pattern
# arn:aws:dynamodb:<region>:<account>:table/<name> — same string with
# different region — so the wildcard region match here is fine.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "secondary_worker_policy" {
  count = local.is_multi_region

  statement {
    sid = "SQSPrimes"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:SendMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [
      aws_sqs_queue.secondary_primes[0].arn,
      aws_sqs_queue.secondary_primes_dlq[0].arn,
    ]
  }

  # DDB executions table — both replicas (Global Tables shares one ARN per
  # region, but principal needs both regions' ARNs to write locally + read
  # cross-region for failover diagnostics).
  statement {
    sid = "DynamoDBExecutions"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:DescribeTable",
    ]
    resources = [
      aws_dynamodb_table.executions.arn,
      "${aws_dynamodb_table.executions.arn}/index/*",
      "arn:aws:dynamodb:${var.secondary_region}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_name}",
      "arn:aws:dynamodb:${var.secondary_region}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_name}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "secondary_worker_inline" {
  count    = local.is_multi_region
  provider = aws.secondary

  name   = "aegis-enclave-secondary-worker-inline"
  role   = aws_iam_role.secondary_worker[0].id
  policy = data.aws_iam_policy_document.secondary_worker_policy[0].json
}

resource "aws_iam_role_policy_attachment" "secondary_worker_ecr" {
  count    = local.is_multi_region
  provider = aws.secondary

  role       = aws_iam_role.secondary_worker[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "secondary_worker_logs" {
  count    = local.is_multi_region
  provider = aws.secondary

  role       = aws_iam_role.secondary_worker[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

# ─── Secondary SQS (region-local; messages don't cross regions) ────────────
resource "aws_sqs_queue" "secondary_primes_dlq" {
  count    = local.is_multi_region
  provider = aws.secondary

  name                      = "aegis-enclave-secondary-primes-dlq"
  message_retention_seconds = 1209600
  receive_wait_time_seconds = 0
}

resource "aws_sqs_queue" "secondary_primes" {
  count    = local.is_multi_region
  provider = aws.secondary

  name                       = "aegis-enclave-secondary-primes"
  visibility_timeout_seconds = var.sqs_visibility_timeout
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.secondary_primes_dlq[0].arn
    maxReceiveCount     = 3
  })
}

# ─── Secondary Valkey (region-local cache) ────────────────────────────────
resource "aws_elasticache_serverless_cache" "secondary_valkey" {
  count    = local.is_multi_region
  provider = aws.secondary

  engine = "valkey"
  name   = "aegis-enclave-secondary-valkey"

  cache_usage_limits {
    data_storage {
      maximum = var.valkey_max_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.valkey_max_ecpu_per_sec
    }
  }

  snapshot_retention_limit = 0

  subnet_ids         = aws_subnet.secondary_private[*].id
  security_group_ids = [aws_security_group.secondary_valkey[0].id]
}

# ─── Secondary ECS task definitions: app, worker, bootstrap ────────────────
resource "aws_ecs_task_definition" "secondary_app" {
  count    = local.is_multi_region
  provider = aws.secondary

  family                   = "aegis-enclave-secondary-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  task_role_arn      = aws_iam_role.secondary_worker[0].arn
  execution_role_arn = aws_iam_role.secondary_worker[0].arn

  container_definitions = jsonencode([{
    name = "app"
    # Image lives in the secondary-region ECR — operator must `docker push`
    # to both regions during cloud-up. cloud-up.sh handles this when
    # secondary_region is set (see scripts/cloud-up.sh follow-up commit).
    image = "${aws_ecr_repository.secondary[0].repository_url}:${var.image_tag}"
    portMappings = [{
      containerPort = 8000
      protocol      = "tcp"
    }]
    environment = [
      { name = "DYNAMODB_TABLE_NAME", value = aws_dynamodb_table.executions.name },
      { name = "AWS_DEFAULT_REGION", value = var.secondary_region },
    ]
    stopTimeout = 60
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/aegis-enclave-secondary-app"
        "awslogs-region"        = var.secondary_region
        "awslogs-stream-prefix" = "app"
      }
    }
    essential              = true
    readonlyRootFilesystem = false
  }])
}

resource "aws_ecs_service" "secondary_app" {
  count    = local.is_multi_region
  provider = aws.secondary

  name            = "aegis-enclave-secondary-app"
  cluster         = aws_ecs_cluster.secondary[0].id
  task_definition = aws_ecs_task_definition.secondary_app[0].arn
  desired_count   = 3
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.secondary_private[*].id
    security_groups  = [aws_security_group.secondary_app[0].id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.secondary_app[0].arn
    container_name   = "app"
    container_port   = 8000
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  depends_on = [aws_lb_listener.secondary_https]
}

resource "aws_ecs_task_definition" "secondary_worker" {
  count    = local.is_multi_region
  provider = aws.secondary

  family                   = "aegis-enclave-secondary-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024

  task_role_arn      = aws_iam_role.secondary_worker[0].arn
  execution_role_arn = aws_iam_role.secondary_worker[0].arn

  container_definitions = jsonencode([{
    name        = "worker"
    image       = "${aws_ecr_repository.secondary[0].repository_url}:${var.image_tag}"
    command     = ["python", "-m", "prime_service.worker"]
    stopTimeout = 65
    environment = [
      { name = "DYNAMODB_TABLE_NAME", value = aws_dynamodb_table.executions.name },
      { name = "AWS_DEFAULT_REGION", value = var.secondary_region },
      { name = "VALKEY_ENDPOINT", value = "${aws_elasticache_serverless_cache.secondary_valkey[0].endpoint[0].address}:${aws_elasticache_serverless_cache.secondary_valkey[0].endpoint[0].port}" },
      { name = "VALKEY_TLS", value = "true" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/aegis-enclave-secondary-worker"
        "awslogs-region"        = var.secondary_region
        "awslogs-stream-prefix" = "worker"
      }
    }
    essential              = true
    readonlyRootFilesystem = false
  }])
}

resource "aws_ecs_service" "secondary_worker" {
  count    = local.is_multi_region
  provider = aws.secondary

  name            = "aegis-enclave-secondary-worker"
  cluster         = aws_ecs_cluster.secondary[0].id
  task_definition = aws_ecs_task_definition.secondary_worker[0].arn
  desired_count   = var.worker_min_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.secondary_private[*].id
    security_groups  = [aws_security_group.secondary_worker[0].id]
    assign_public_ip = false
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_ecs_task_definition" "secondary_bootstrap" {
  count    = local.is_multi_region
  provider = aws.secondary

  family                   = "aegis-enclave-secondary-cache-bootstrap"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  task_role_arn      = aws_iam_role.secondary_worker[0].arn
  execution_role_arn = aws_iam_role.secondary_worker[0].arn

  container_definitions = jsonencode([{
    name    = "bootstrap"
    image   = "${aws_ecr_repository.secondary[0].repository_url}:${var.image_tag}"
    command = ["python", "-m", "prime_service.bootstrap"]
    environment = [
      { name = "DYNAMODB_TABLE_NAME", value = aws_dynamodb_table.executions.name },
      { name = "AWS_DEFAULT_REGION", value = var.secondary_region },
      { name = "VALKEY_ENDPOINT", value = "${aws_elasticache_serverless_cache.secondary_valkey[0].endpoint[0].address}:${aws_elasticache_serverless_cache.secondary_valkey[0].endpoint[0].port}" },
      { name = "VALKEY_TLS", value = "true" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/aegis-enclave-secondary-bootstrap"
        "awslogs-region"        = var.secondary_region
        "awslogs-stream-prefix" = "bootstrap"
      }
    }
    essential              = true
    readonlyRootFilesystem = false
  }])
}

# ─── Secondary Client VPN (1 server cert per region per ADR-0024) ──────────
resource "aws_ec2_client_vpn_endpoint" "secondary" {
  count    = local.is_multi_region
  provider = aws.secondary

  description            = "aegis-enclave secondary Client VPN - operator access to ${var.secondary_region}"
  server_certificate_arn = var.secondary_server_cert_arn != "" ? var.secondary_server_cert_arn : var.server_cert_arn
  client_cidr_block      = "10.21.0.0/16" # avoid both VPC CIDRs + primary VPN CIDR

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.secondary_client_cert_arn != "" ? var.secondary_client_cert_arn : var.client_cert_arn
  }

  connection_log_options {
    enabled = false
  }

  vpc_id             = aws_vpc.secondary[0].id
  security_group_ids = [aws_security_group.secondary_alb[0].id]

  split_tunnel = true
  dns_servers  = []

  tags = { Name = "aegis-enclave-secondary-vpn" }
}

resource "aws_ec2_client_vpn_network_association" "secondary_az_a" {
  count    = local.is_multi_region
  provider = aws.secondary

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.secondary[0].id
  subnet_id              = aws_subnet.secondary_private[0].id
}

resource "aws_ec2_client_vpn_network_association" "secondary_az_b" {
  count    = local.is_multi_region
  provider = aws.secondary

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.secondary[0].id
  subnet_id              = aws_subnet.secondary_private[1].id
}

resource "aws_ec2_client_vpn_network_association" "secondary_az_c" {
  count    = local.is_multi_region
  provider = aws.secondary

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.secondary[0].id
  subnet_id              = aws_subnet.secondary_private[2].id
}

resource "aws_ec2_client_vpn_authorization_rule" "secondary_vpc_access" {
  count    = local.is_multi_region
  provider = aws.secondary

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.secondary[0].id
  target_network_cidr    = var.secondary_vpc_cidr
  authorize_all_groups   = true
  description            = "Authorize VPN clients to reach secondary VPC services"
}

# ═══════════════════════════════════════════════════════════════════════════
# ROUTE53 (multi-region only — weighted A records 50/50 with health checks)
# ═══════════════════════════════════════════════════════════════════════════
# Conditional on BOTH multi-region and route53_zone_name. Forker provides an
# existing hosted zone via var.route53_zone_name; we look it up via data
# source and create two weighted A records (one per region) plus per-region
# health checks.
#
# Health checks target the ALB IPs via /health endpoint. Since the ALBs are
# internal, the health check comes from a Route53 health checker IP — which
# does NOT have VPC access. The acceptable production-shape pattern is to
# pair Route53 health check with a CloudWatch alarm-based health check (via
# `cloudwatch_alarm_region` + `cloudwatch_alarm_name`), tied to the per-
# region ALB's CloudWatch metric `HealthyHostCount`. That keeps the health
# signal on-VPC without exposing a public health endpoint.

data "aws_route53_zone" "main" {
  count = local.multi_region_count

  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_cloudwatch_metric_alarm" "primary_alb_health" {
  count = local.multi_region_count

  alarm_name          = "aegis-enclave-primary-alb-health"
  alarm_description   = "Primary ALB has 0 healthy targets - Route53 health check feeds off this."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "breaching"

  metric_name = "HealthyHostCount"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Maximum"

  dimensions = {
    LoadBalancer = module.alb.arn_suffix
    TargetGroup  = module.alb.target_groups["app"].arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "secondary_alb_health" {
  count    = local.multi_region_count
  provider = aws.secondary

  alarm_name          = "aegis-enclave-secondary-alb-health"
  alarm_description   = "Secondary ALB has 0 healthy targets - Route53 health check feeds off this."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "breaching"

  metric_name = "HealthyHostCount"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Maximum"

  dimensions = {
    LoadBalancer = aws_lb.secondary[0].arn_suffix
    TargetGroup  = aws_lb_target_group.secondary_app[0].arn_suffix
  }
}

resource "aws_route53_health_check" "primary" {
  count = local.multi_region_count

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.primary_alb_health[0].alarm_name
  cloudwatch_alarm_region         = var.region
  insufficient_data_health_status = "Unhealthy"

  tags = { Name = "aegis-enclave-primary-health" }
}

resource "aws_route53_health_check" "secondary" {
  count = local.multi_region_count

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.secondary_alb_health[0].alarm_name
  cloudwatch_alarm_region         = var.secondary_region
  insufficient_data_health_status = "Unhealthy"

  tags = { Name = "aegis-enclave-secondary-health" }
}

# Weighted records — 50/50 split. Each record points at its region's ALB DNS
# (alias). Route53 stops returning the alias when the linked health check
# transitions to unhealthy.
resource "aws_route53_record" "primary" {
  count = local.multi_region_count

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.alb_internal_hostname
  type    = "A"

  set_identifier = "primary-${var.region}"
  weighted_routing_policy {
    weight = 50
  }

  alias {
    name                   = module.alb.dns_name
    zone_id                = module.alb.zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.primary[0].id
}

resource "aws_route53_record" "secondary" {
  count = local.multi_region_count

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.alb_internal_hostname
  type    = "A"

  set_identifier = "secondary-${var.secondary_region}"
  weighted_routing_policy {
    weight = 50
  }

  alias {
    name                   = aws_lb.secondary[0].dns_name
    zone_id                = aws_lb.secondary[0].zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.secondary[0].id
}
