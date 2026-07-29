# alb.tf — internal ALB + its self-signed TLS certificate (ADR-0027).
#
# The internal ALB terminates TLS so the operator's curl uses https:// — same
# protocol as a production deployment. Self-signed (not a public-CA ACM cert)
# because the hostname is internal-only; ACM Private CA is $400/mo overkill for
# a bounded acceptance window. Imported into ACM as a regular certificate —
# no charge for imports.

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
  version = "10.5.0" # exact pin (case-study reproducibility); was ~> 9.9

  name    = "${var.name_prefix}-alb"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  internal           = true # not internet-facing — only VPN-reachable
  load_balancer_type = "application"

  # Bounded apply-then-destroy acceptance window (ADR-0034). Production
  # deployments should override to true.
  enable_deletion_protection = false

  # Three-layer timeout defence (ADR-0020): app wait_for is 30s + 10s, ALB
  # sits at 45s so the client sees the application's 504 rather than a reset.
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
      # module.ecs.services["app"]).
      create_attachment = false

      # ADR-0033 — Drain semantics (API tier). 60s matches the longest
      # legitimate compute path (30s prime budget + 10s audit + slack).
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
