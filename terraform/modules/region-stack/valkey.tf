# valkey.tf — distributed cache for this region (ElastiCache Serverless Valkey,
# ADR-0031). Region-local cache; does not cross-replicate.

resource "aws_elasticache_serverless_cache" "valkey" {
  engine = "valkey"
  name   = "${var.name_prefix}-valkey"

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
