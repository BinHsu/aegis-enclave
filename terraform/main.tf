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
  description = "VPC Endpoint ENI inbound — HTTPS from within the VPC"
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
  description = "Internal ALB — reachable only from VPC (Client VPN clients arrive via VPC routes)"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.vpc_cidr]
  ingress_rules       = ["http-80-tcp"]
  egress_rules        = ["all-all"]
}

module "app_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.2"

  name        = "aegis-enclave-app-sg"
  description = "Application service — accept traffic only from internal ALB"
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
  description = "PostgreSQL — accept traffic only from app service"
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
  engine_version       = "16.3"
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

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
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
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.11"

  cluster_name = "aegis-enclave"

  cluster_configuration = {
    execute_command_configuration = {
      logging = "DEFAULT"
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
          image = "${module.ecr.repository_url}:latest"
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
  description            = "aegis-enclave Client VPN — operator + ground-station access"
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
