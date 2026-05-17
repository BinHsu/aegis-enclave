# versions.tf — provider requirements for the region-stack module.
#
# This module is the regional layer of the aegis-enclave deployment: one
# instance is created per AWS region (see the root main.tf module calls).
# Because Terraform cannot pass a per-instance provider to a for_each/count
# module, the root instantiates this module with EXPLICIT module calls and
# passes the correct regional `aws` provider via `providers = { ... }`.
#
# `configuration_aliases` is intentionally NOT declared here: the module
# consumes a single (default) `aws` provider plus the default `tls` provider.
# The root decides WHICH regional aws provider to hand in per module call
# (`aws` for the platform region, `aws.peer` for the peer region).

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
}
