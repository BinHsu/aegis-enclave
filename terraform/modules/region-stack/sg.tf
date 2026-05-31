# sg.tf — security groups for the ALB -> app -> worker -> valkey chain.
#
# No RDS SG per ADR-0042 (DynamoDB is reached via the gateway VPC endpoint,
# which is route-table-attached, not SG-attached).

module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.1" # exact pin (case-study reproducibility); was ~> 5.2

  name        = "${var.name_prefix}-alb-sg"
  description = "Internal ALB - reachable only from VPC (Client VPN clients arrive via VPC routes)"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [local.effective_cidr] # ADR-0050: IPAM-aware (var.vpc_cidr is null in IPAM mode)
  ingress_rules       = ["https-443-tcp"]      # ADR-0027 — HTTPS-only listener.
  egress_rules        = ["all-all"]
}

module "app_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.1" # exact pin (case-study reproducibility); was ~> 5.2

  name        = "${var.name_prefix}-app-sg"
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

# ─── Worker SG ──────────────────────────────────────────────────────────────
resource "aws_security_group" "worker" {
  name        = "${var.name_prefix}-worker-sg"
  description = "Worker ECS task - egress to SQS VPC endpoint, Valkey, DDB, ECR"
  vpc_id      = module.vpc.vpc_id

  # No ingress - worker only pulls from SQS, never receives inbound traffic.
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Accepted: worker is in private subnets with no ingress and no public
    # route. Scoping egress to VPC CIDR would break S3/DDB gateway-endpoint
    # traffic (managed prefix lists, not VPC CIDR) — ECR layer pulls included.
    # Prefix-list-scoped egress is the production-hardening path.
    #tfsec:ignore:aws-ec2-no-public-egress-sgr
    cidr_blocks = ["0.0.0.0/0"]
    description = "Unrestricted egress - worker reaches SQS endpoint, Valkey, DDB, ECR via VPC endpoints"
  }

  tags = { Name = "${var.name_prefix}-worker-sg" }
}

# ─── Valkey SG ──────────────────────────────────────────────────────────────
resource "aws_security_group" "valkey" {
  name        = "${var.name_prefix}-valkey-sg"
  description = "ElastiCache Serverless Valkey - accept inbound 6379 from ECS tasks only"
  vpc_id      = module.vpc.vpc_id

  # Egress: unrestricted (required for cluster-mode inter-node traffic internal
  # to ElastiCache).
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Accepted: documented ElastiCache Serverless internal-cluster requirement.
    #tfsec:ignore:aws-ec2-no-public-egress-sgr
    cidr_blocks = ["0.0.0.0/0"]
    description = "Unrestricted egress - ElastiCache Serverless requirement"
  }

  tags = { Name = "${var.name_prefix}-valkey-sg" }
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

# Allow the worker ECS tasks to reach Valkey. The cache_bootstrap task reuses
# aws_security_group.worker, so this rule also authorises bootstrap traffic.
resource "aws_security_group_rule" "worker_to_valkey" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  description              = "Worker ECS task to Valkey 6379"
  security_group_id        = aws_security_group.valkey.id
  source_security_group_id = aws_security_group.worker.id
}
