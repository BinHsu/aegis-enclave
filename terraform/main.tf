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
# module "vpc" {
#   source  = "terraform-aws-modules/vpc/aws"
#   version = "~> 5.8"
#
#   name = "aegis-enclave-vpc"
#   cidr = var.vpc_cidr
#
#   azs              = ["${var.region}a", "${var.region}b"]
#   private_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
#   public_subnets   = ["10.0.101.0/24", "10.0.102.0/24"]
#   database_subnets = ["10.0.201.0/24", "10.0.202.0/24"]
#
#   enable_nat_gateway   = true
#   single_nat_gateway   = true # Phase 1 cost discipline; multi-NAT is a Phase 2 toggle
#   enable_dns_hostnames = true
# }

# ─── Database (ADR-0009: RDS PostgreSQL, multi_az = true) ──────────────────
# module "rds" {
#   source  = "terraform-aws-modules/rds/aws"
#   version = "~> 6.7"
#
#   identifier     = "aegis-enclave-pg"
#   engine         = "postgres"
#   engine_version = "16.3"
#   instance_class = "db.t4g.micro"
#
#   multi_az = true # ADR-0009: free architectural credit, supports RPO target in ADR-0008
#
#   db_name                     = "primes"
#   username                    = "primes_app"
#   manage_master_user_password = true # Secrets Manager integration
#
#   db_subnet_group_name = module.vpc.database_subnet_group_name
# }

# ─── Compute (ADR-0015: ECS Fargate over EKS — no K8s control-plane fee) ───
# module "ecs" {
#   source  = "terraform-aws-modules/ecs/aws"
#   version = "~> 5.11"
#   # cluster definition + Fargate capacity provider
#   # task definition referencing ECR image
# }

# ─── Internal load balancer (private, behind Client VPN endpoint) ──────────
# module "alb" {
#   source  = "terraform-aws-modules/alb/aws"
#   version = "~> 9.9"
#   # internal = true; only reachable through Client VPN
# }

# ─── VPN (ADR-0006: AWS Client VPN endpoint primary, NetBird alternative) ──
# resource "aws_ec2_client_vpn_endpoint" "main" {
#   description            = "aegis-enclave Client VPN"
#   server_certificate_arn = var.server_cert_arn
#   client_cidr_block      = "10.20.0.0/16"
#   # mutual TLS auth; subnet associations for HA
# }

# ─── Secrets and registry ──────────────────────────────────────────────────
# resource "aws_secretsmanager_secret" "db_password" { ... }
# resource "aws_ecr_repository" "app" { ... }
