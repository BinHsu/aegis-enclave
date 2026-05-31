# network.tf — VPC, VPC endpoints, and Client VPN for one region.
#
# ADR-0019 — Private-only VPC: no public subnets, no IGW, no NAT. AWS service
# egress goes through VPC Endpoints; the VPC has no public-internet egress.
# ADR-0007 reconsidered (04/28): 3-AZ private posture.

# ADR-0050 — IPAM-aware VPC addressing. When the region opts into IPAM
# (ipv4_ipam_pool_id set), preview the next CIDR IPAM would allocate at the
# requested netmask, so the subnet / SG / VPN derivations have a concrete value
# at PLAN time (the VPC's own use_ipam_pool allocation is known only after
# apply, and feeding it back into the subnets would be circular). The VPC still
# allocates via use_ipam_pool — one tracked allocation. preview == actual under
# our serial, one-VPC-per-pool apply; a concurrent grab from the same pool would
# make them diverge, which fails LOUD at apply (a subnet falls outside the VPC
# CIDR), never silently. See ADR-0050 § Consequences.
data "aws_vpc_ipam_preview_next_cidr" "vpc" {
  count          = var.ipv4_ipam_pool_id != null ? 1 : 0
  ipam_pool_id   = var.ipv4_ipam_pool_id
  netmask_length = var.ipv4_netmask_length
}

locals {
  use_ipam = var.ipv4_ipam_pool_id != null

  # The address space every per-region derivation reads: the static CIDR when
  # set, else the IPAM-previewed CIDR (both known at plan time).
  effective_cidr = local.use_ipam ? data.aws_vpc_ipam_preview_next_cidr.vpc[0].cidr : var.vpc_cidr

  # Three /24 private subnets derived from the region's /16 effective CIDR.
  # cidrsubnet(cidr, 8, 1|2|3) -> x.x.1.0/24, x.x.2.0/24, x.x.3.0/24 —
  # matches the pre-refactor hand-written 10.0.1/2/3.0/24 layout.
  private_subnet_cidrs = [
    cidrsubnet(local.effective_cidr, 8, 1),
    cidrsubnet(local.effective_cidr, 8, 2),
    cidrsubnet(local.effective_cidr, 8, 3),
  ]

  azs = ["${var.region}a", "${var.region}b", "${var.region}c"]

  # 9 interface endpoints per ADR-0019 (ecr.api / ecr.dkr / secretsmanager /
  # logs / ecs / ecs-agent / ecs-telemetry / sts / sqs).
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

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0" # exact pin (case-study reproducibility); was ~> 5.8

  name = "${var.name_prefix}-vpc"
  cidr = local.use_ipam ? null : var.vpc_cidr

  # ADR-0050: allocate the VPC CIDR from IPAM when a pool is provided; otherwise
  # use the static cidr above. The module sets aws_vpc.cidr_block = null and
  # populates ipv4_ipam_pool_id + ipv4_netmask_length under use_ipam_pool.
  use_ipam_pool       = local.use_ipam
  ipv4_ipam_pool_id   = var.ipv4_ipam_pool_id
  ipv4_netmask_length = local.use_ipam ? var.ipv4_netmask_length : null

  # ADR-0007 reconsidered (04/28): 3 AZs. ECS spreads tasks across 3 fault
  # domains; AZ loss leaves 2/3 capacity. database_subnets removed (no RDS).
  azs             = local.azs
  private_subnets = local.private_subnet_cidrs
  # public_subnets intentionally absent — see ADR-0019.
  # database_subnets intentionally absent — see ADR-0042 (DDB is regional-managed).

  enable_nat_gateway   = false # ADR-0019 — no public-internet egress
  enable_dns_hostnames = true
  enable_dns_support   = true # required for VPC Endpoints to resolve
}

# ─── VPC Endpoints (ADR-0019: AWS API egress via PrivateLink) ───────────────

module "vpc_endpoints_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.1" # exact pin (case-study reproducibility); was ~> 5.2

  name        = "${var.name_prefix}-vpc-endpoints-sg"
  description = "VPC Endpoint ENI inbound - HTTPS from within the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [local.effective_cidr]
  ingress_rules       = ["https-443-tcp"]
  egress_rules        = ["all-all"]
}

# Gateway endpoints — S3 + DynamoDB (free; ECR uses S3 for layer storage,
# the DDB gateway endpoint routes app/worker SDK traffic).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "${var.name_prefix}-s3-gateway" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "${var.name_prefix}-dynamodb-gateway" }
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each = local.interface_endpoints

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [module.vpc_endpoints_sg.security_group_id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-${replace(each.value, ".", "-")}" }
}

# ─── Client VPN (ADR-0006: AWS Client VPN endpoint, mutual-TLS) ─────────────
resource "aws_ec2_client_vpn_endpoint" "main" {
  description            = "${var.name_prefix} Client VPN - operator + ground-station access"
  server_certificate_arn = var.server_cert_arn
  client_cidr_block      = var.vpn_client_cidr

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

  tags = { Name = "${var.name_prefix}-vpn" }
}

# One network association per AZ — VPN clients reach all three private subnets.
resource "aws_ec2_client_vpn_network_association" "az" {
  count = 3

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.main.id
  subnet_id              = module.vpc.private_subnets[count.index]
}

resource "aws_ec2_client_vpn_authorization_rule" "vpc_access" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.main.id
  target_network_cidr    = local.effective_cidr
  authorize_all_groups   = true
  description            = "Authorize VPN clients to reach VPC services"
}
