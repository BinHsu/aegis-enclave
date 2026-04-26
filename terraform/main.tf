# main.tf — STUB
#
# Phase 1 build will fill in the module compositions. This stub establishes:
#   - Provider with default_tags for FinOps cost attribution (ADR-0006 cost analysis posture)
#   - Community-module references (ADR-0016) — `terraform-aws-modules/*` over hand-rolled
#   - Single-region eu-central-1 (ADR-0007), Multi-AZ standby for RDS (ADR-0009)
#   - Plan-only deliverable per ADR-0015 — never apply during the case-study cycle.
#
# To plan: `make tf-plan` (runs `terraform init -backend=false && terraform plan`).
# Phase 2 cross-cloud migration spec lives in `docs/migration_runbook.md`.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
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

  # ─── Phase-2 state backend (commented out; see ADR-0025) ──────────────
  # Uncomment and fill in `bucket` + `dynamodb_table` from the outputs of
  # `terraform/bootstrap/` after running it once. Phase-1 deliverable runs
  # `terraform plan -backend=false`, so this stays commented for the
  # case-study cycle.
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

# ─── Network (ADR-0007: single-region eu-central-1, multi-AZ) ──────────────
# ADR-0019 — Private-only VPC: no public subnets, no IGW, no NAT.
# AWS service egress goes through VPC Endpoints (declared below); the VPC
# has no public-internet egress path at all.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "aegis-enclave-vpc"
  cidr = var.vpc_cidr

  azs              = ["${var.region}a", "${var.region}b"]
  private_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  database_subnets = ["10.0.201.0/24", "10.0.202.0/24"]
  # public_subnets intentionally absent — see ADR-0019.

  enable_nat_gateway   = false # ADR-0019 — no public-internet egress
  enable_dns_hostnames = true
  enable_dns_support   = true # required for VPC Endpoints to resolve

  create_database_subnet_group = true
}

# ─── VPC Endpoints (ADR-0019: private-only VPC, AWS API egress via PrivateLink) ──

# Security group permitting HTTPS from the VPC CIDR to the endpoint ENIs.
module "vpc_endpoints_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.2"

  name        = "aegis-enclave-vpc-endpoints-sg"
  description = "VPC Endpoint ENI inbound - HTTPS from within the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.vpc_cidr]
  ingress_rules       = ["https-443-tcp"]
  egress_rules        = ["all-all"]
}

# Gateway endpoint — S3 (free; ECR uses S3 for layer storage).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "aegis-enclave-s3-gateway" }
}

# Interface endpoints — for AWS service APIs that the workload calls.
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

# ─── Security groups (ALB → app → RDS chain) ───────────────────────────────
module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.2"

  name        = "aegis-enclave-alb-sg"
  description = "Internal ALB - reachable only from VPC (Client VPN clients arrive via VPC routes)"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.vpc_cidr]
  ingress_rules       = ["https-443-tcp"] # ADR-0027 — HTTPS-only listener; HTTP not exposed.
  egress_rules        = ["all-all"]
}

module "app_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.2"

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

module "rds_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.2"

  name        = "aegis-enclave-rds-sg"
  description = "PostgreSQL - accept traffic only from app service"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [{
    from_port                = 5432
    to_port                  = 5432
    protocol                 = "tcp"
    description              = "PostgreSQL from app"
    source_security_group_id = module.app_sg.security_group_id
  }]
  egress_rules = ["all-all"]
}

# ─── Database (ADR-0009: RDS PostgreSQL, multi_az = true) ──────────────────
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.7"

  identifier = "aegis-enclave-pg"

  engine               = "postgres"
  engine_version       = "16.13"
  family               = "postgres16"
  major_engine_version = "16"

  instance_class        = "db.t4g.micro"
  allocated_storage     = 20
  max_allocated_storage = 100

  multi_az = true # ADR-0009 — free architectural credit, supports RPO target in ADR-0008

  db_name                     = "primes"
  username                    = "primes_app"
  port                        = 5432
  manage_master_user_password = true # Secrets Manager integration; no plaintext password in code

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [module.rds_sg.security_group_id]

  backup_retention_period = 7
  skip_final_snapshot     = true  # case-study scope
  deletion_protection     = false # case-study scope

  performance_insights_enabled = false
  monitoring_interval          = 0
}

# ─── Container registry (ECR with scan-on-push + immutable tags) ───────────
module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 2.3"

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
  version = "~> 9.9"

  name    = "aegis-enclave-alb"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  internal           = true # not internet-facing — only VPN-reachable
  load_balancer_type = "application"

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

      # ADR-0022 — Drain semantics. Default 300s drains existing connections
      # for 5 minutes after deregister, which is wildly long for a case-study
      # PoC (and means rolling deploys block on the slowest in-flight request
      # for 5 minutes). 60s matches the longest legitimate compute path
      # (30s prime budget + 10s audit + slack).
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
  version = "~> 5.11.0"

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

      container_definitions = {
        app = {
          image = "${module.ecr.repository_url}:${var.image_tag}"
          port_mappings = [{
            containerPort = 8000
            protocol      = "tcp"
          }]
          environment = [
            { name = "POSTGRES_HOST", value = module.rds.db_instance_address },
            { name = "POSTGRES_PORT", value = "5432" },
            { name = "POSTGRES_USER", value = "primes_app" },
            { name = "POSTGRES_DB", value = "primes" },
          ]
          secrets = [
            { name = "POSTGRES_PASSWORD", valueFrom = module.rds.db_instance_master_user_secret_arn },
          ]

          # ADR-0022 — Drain semantics. ECS sends SIGTERM, waits stop_timeout,
          # then SIGKILL. Set to 60s so it strictly exceeds uvicorn's
          # `--timeout-graceful-shutdown 45` (Dockerfile) — a request that
          # started just before SIGTERM still has 45s to finish before
          # uvicorn drops it, and ECS waits another 15s before SIGKILL.
          stop_timeout = 60

          readonly_root_filesystem = false # FastAPI/uvicorn writes to tmpdir
          essential                = true
        }
      }

      load_balancer = {
        service = {
          target_group_arn = module.alb.target_groups["app"].arn
          container_name   = "app"
          container_port   = 8000
        }
      }

      subnet_ids         = module.vpc.private_subnets
      security_group_ids = [module.app_sg.security_group_id]
    }
  }
}

# ─── Phase-2 auto-scaling (commented out; see ADR-0023) ──────────────────
# Uncomment when promoting from case-study (desired_count = 1) to a real
# deployment. min_capacity = 2 spreads tasks across the two private
# subnets declared in module.vpc — single-AZ failure no longer takes the
# workload offline. target_value = 60 % CPU leaves 40 % headroom for the
# ~30s Fargate cold start before a scale-out task is healthy.
#
# resource "aws_appautoscaling_target" "app" {
#   max_capacity       = 10
#   min_capacity       = 2
#   resource_id        = "service/${module.ecs.cluster_name}/${module.ecs.services["app"].name}"
#   scalable_dimension = "ecs:service:DesiredCount"
#   service_namespace  = "ecs"
# }
#
# resource "aws_appautoscaling_policy" "cpu" {
#   name               = "cpu-target-tracking"
#   policy_type        = "TargetTrackingScaling"
#   resource_id        = aws_appautoscaling_target.app.resource_id
#   scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
#   service_namespace  = aws_appautoscaling_target.app.service_namespace
#
#   target_tracking_scaling_policy_configuration {
#     predefined_metric_specification {
#       predefined_metric_type = "ECSServiceAverageCPUUtilization"
#     }
#     target_value       = 60
#     scale_in_cooldown  = 300   # 5 min — be conservative scaling down
#     scale_out_cooldown = 60    # 1 min — be aggressive scaling up
#   }
# }

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

resource "aws_ec2_client_vpn_authorization_rule" "vpc_access" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.main.id
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
  description            = "Authorize VPN clients to reach VPC services"
}

# ─── Phase 2.3 — Async job queue (SQS) ──────────────────────────────────────
# Queue for prime-computation jobs. Visibility timeout = compute_budget × 1.5
# so a message re-delivers if the worker crashes without acking.
# DLQ redrive is a design-only skeleton (max_receive_count = 3 → see dead-letter
# queue wiring below). DLQ itself is deferred to L5 per strategy.md § D.

resource "aws_sqs_queue" "primes_dlq" {
  name                      = "aegis-enclave-primes-dlq"
  message_retention_seconds = 1209600 # 14 days — max; keeps failed messages for analysis
  receive_wait_time_seconds = 0
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

# ─── Phase 2.4 — Distributed cache (ElastiCache Serverless Valkey) ──────────
# Serverless variant: no instance sizing, cost scales with actual usage.
# Caps are set conservatively for the 3-hour cloud-acceptance window (< $2):
#   data_storage.maximum = 1 GB    (well above the 100 MB floor)
#   ecpu_per_second.maximum = 5000 (covers burst traffic at PoC scale)
# snapshot_retention_limit = 0 → no automatic snapshots (cost + privacy guard).
#
# Security group: allow inbound 6379 from the worker and app task security groups.

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

# Allow the bootstrap ECS task to reach Valkey.
# Note: bootstrap_to_valkey rule removed - cache_bootstrap ECS task uses
# aws_security_group.worker (same SG as worker), so worker_to_valkey already
# authorises bootstrap traffic. AWS rejected the duplicate rule
# (InvalidPermission.Duplicate). If bootstrap ever needs its own SG, add a
# separate aws_security_group.bootstrap and a corresponding rule.

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

# ─── Phase 2.3 — IAM role for the worker ECS task ───────────────────────────
# Permissions needed by the worker and bootstrap containers:
#   - SQS: receive, delete, get-queue-attributes (worker poll + ack + depth)
#   - Valkey: no IAM — authenticated by network isolation (SG) only
#   - RDS: connect via IAM auth is not used here (Secrets Manager provides creds)
#   - Secrets Manager: read the RDS password secret
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

  # Secrets Manager: read the RDS master-user secret (password for DB connection).
  statement {
    sid       = "SecretsManagerRDS"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.rds.db_instance_master_user_secret_arn]
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
  description = "Worker ECS task - egress to SQS VPC endpoint, Valkey, RDS, ECR"
  vpc_id      = module.vpc.vpc_id

  # No ingress - worker only pulls from SQS, never receives inbound traffic.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Unrestricted egress - worker reaches SQS endpoint, Valkey, RDS, ECR via VPC endpoints"
  }

  tags = { Name = "aegis-enclave-worker-sg" }
}

# ─── ECS task definition: worker ─────────────────────────────────────────────

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

    environment = [
      { name = "POSTGRES_HOST", value = module.rds.db_instance_address },
      { name = "POSTGRES_PORT", value = "5432" },
      { name = "POSTGRES_USER", value = "primes_app" },
      { name = "POSTGRES_DB", value = "primes" },
      { name = "VALKEY_ENDPOINT", value = "${aws_elasticache_serverless_cache.valkey.endpoint[0].address}:${aws_elasticache_serverless_cache.valkey.endpoint[0].port}" },
      { name = "VALKEY_TLS", value = "true" },
      # NullPool avoids event-loop conflicts when asyncio.run() is called
      # multiple times in the sync worker loop. See db.py for rationale.
      { name = "DATABASE_POOL_CLASS", value = "null" },
    ]

    secrets = [
      { name = "POSTGRES_PASSWORD", valueFrom = module.rds.db_instance_master_user_secret_arn },
    ]

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

# ─── ECS task definition: cache_bootstrap ────────────────────────────────────
# One-shot task — triggered by null_resource after Valkey is ready.
# 256 CPU / 512 MB — bootstrap just runs a sieve + single Redis write.

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
      { name = "POSTGRES_HOST", value = module.rds.db_instance_address },
      { name = "POSTGRES_PORT", value = "5432" },
      { name = "POSTGRES_USER", value = "primes_app" },
      { name = "POSTGRES_DB", value = "primes" },
      { name = "VALKEY_ENDPOINT", value = "${aws_elasticache_serverless_cache.valkey.endpoint[0].address}:${aws_elasticache_serverless_cache.valkey.endpoint[0].port}" },
      { name = "VALKEY_TLS", value = "true" },
      { name = "DATABASE_POOL_CLASS", value = "null" },
    ]

    secrets = [
      { name = "POSTGRES_PASSWORD", valueFrom = module.rds.db_instance_master_user_secret_arn },
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
# Long-running service (not a one-shot task). Autoscales between
# worker_min_count and worker_max_count based on SQS queue depth.

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

  # Allow ECS to update the service during rolling deploys without
  # destroying the old task before the new one is healthy.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Lifecycle: ignore desired_count changes driven by autoscaling so
  # Terraform doesn't reset the count to var.worker_min_count on every plan.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_ecr,
    aws_iam_role_policy_attachment.worker_logs,
  ]
}

# ─── ECS autoscaling: worker on SQS queue depth ──────────────────────────────
# Target tracking on ApproximateNumberOfMessagesVisible — scale out when queue
# depth exceeds target_value × worker_count. Target value 5 per Q7 (strategy.md § C).

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
# Triggers once after Valkey is ready and the cache_bootstrap task definition
# is registered. The bootstrap task writes primes[1..100000] if absent
# (idempotent — second run exits 0 immediately).
#
# OPERATOR NOTE: `aws ecs run-task` requires the operator to have AWS CLI
# configured with permissions to run ECS tasks. This runs in the Phase 2.5
# cloud-acceptance window where `aws configure` is set. It is a no-op during
# `terraform plan` (local-exec only runs at apply time).

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
