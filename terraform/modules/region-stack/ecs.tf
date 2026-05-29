# ecs.tf — ECS Fargate cluster, app service, worker service, task definitions,
# autoscaling, log groups, and the cache-bootstrap one-shot for this region.
#
# ADR-0015 — ECS Fargate over EKS (no K8s control-plane fee).
# The cluster + app service use the community ecs module; the worker service,
# its task definitions, and the bootstrap are standalone resources.

locals {
  # Region-local Valkey endpoint string consumed by worker + bootstrap envs.
  valkey_endpoint = "${aws_elasticache_serverless_cache.valkey.endpoint[0].address}:${aws_elasticache_serverless_cache.valkey.endpoint[0].port}"
}

# ─── CloudWatch log groups (explicit; 7-day retention) ──────────────────────
# PoC scope: AWS-managed log encryption; customer-managed KMS is a
# production-hardening upgrade (ADR-0003 PoC-scope / prod-hygiene calibration).

#tfsec:ignore:aws-cloudwatch-log-group-customer-key
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name_prefix}-app"
  retention_in_days = 7
}

#tfsec:ignore:aws-cloudwatch-log-group-customer-key
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.name_prefix}-worker"
  retention_in_days = 7
}

#tfsec:ignore:aws-cloudwatch-log-group-customer-key
resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/ecs/${var.name_prefix}-bootstrap"
  retention_in_days = 7
}

# ─── Cluster + app service (community ecs module) ───────────────────────────
module "ecs" {
  source = "terraform-aws-modules/ecs/aws"
  # Pinned to 5.11.x explicitly: 5.12.x introduced a regression in
  # modules/service/main.tf where for_each over container_definitions returns
  # unknown when an inner value references another module's output.
  # Exact-pinned to 5.11.4 (case-study reproducibility).
  version = "5.11.4"

  cluster_name = var.name_prefix

  cluster_configuration = {
    execute_command_configuration = {
      # AWS API requires logging = "OVERRIDE" whenever log_configuration is
      # present (the module auto-adds one when containerInsights is enabled).
      logging = "OVERRIDE"
      log_configuration = {
        cloud_watch_log_group_name = "/aws/ecs/${var.name_prefix}"
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

      # ADR-0007 reconsidered (04/28): app starts at one task per AZ.
      desired_count = var.app_desired_count

      container_definitions = {
        app = {
          image = "${module.ecr.repository_url}:${var.image_tag}"
          port_mappings = [{
            containerPort = 8000
            protocol      = "tcp"
          }]
          # ADR-0042: app talks to DynamoDB via boto3. No POSTGRES_* vars.
          environment = [
            { name = "DYNAMODB_TABLE_NAME", value = var.dynamodb_table_name },
            { name = "AWS_DEFAULT_REGION", value = var.region },
            # ADR-0048: s3_store derives the bucket name as
            # "${prefix}-${AWS_REGION}" at runtime so each task reads/writes
            # its own local CRR replica. Explicit AWS_REGION (not just
            # AWS_DEFAULT_REGION) because boto3.client("s3", ...) inspects
            # AWS_REGION first.
            { name = "AWS_REGION", value = var.region },
            { name = "S3_RESULTS_BUCKET_PREFIX", value = var.result_bucket_prefix },
          ]
          # No secrets — DDB authn is IAM, not Secrets Manager.

          # ADR-0033 — Drain semantics. 60s strictly exceeds uvicorn's
          # --timeout-graceful-shutdown 45 (Dockerfile).
          stop_timeout = 60

          # Explicit log_configuration — avoids the module auto-creating a
          # never-expire log group.
          logConfiguration = {
            logDriver = "awslogs"
            options = {
              "awslogs-group"         = aws_cloudwatch_log_group.app.name
              "awslogs-region"        = var.region
              "awslogs-stream-prefix" = "app"
            }
          }

          readonly_root_filesystem = false # FastAPI/uvicorn writes to tmpdir
          essential                = true
        }
      }

      # Disable the module's auto-created log group — our explicit one above is
      # the canonical destination.
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

      # App POSTs enqueue jobs + writes `queued` rows to DDB. The community
      # module auto-creates the tasks IAM role; we extend it here.
      tasks_iam_role_statements = {
        sqs_enqueue = {
          actions = [
            "sqs:SendMessage",
            "sqs:GetQueueUrl",
            "sqs:GetQueueAttributes",
          ]
          resources = [aws_sqs_queue.primes.arn]
        }
        dynamodb_executions = {
          actions = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:Query",
            "dynamodb:DescribeTable",
          ]
          resources = [var.dynamodb_table_arn]
        }
      }
    }
  }
}

# ─── Worker task definition ─────────────────────────────────────────────────
resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name_prefix}-worker"
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

    # SIGTERM grace: 65s — exceeds the 60s SIGALRM compute budget.
    stopTimeout = 65

    environment = [
      { name = "DYNAMODB_TABLE_NAME", value = var.dynamodb_table_name },
      { name = "AWS_DEFAULT_REGION", value = var.region },
      { name = "VALKEY_ENDPOINT", value = local.valkey_endpoint },
      { name = "VALKEY_TLS", value = "true" },
    ]

    # No secrets block — DDB authn is IAM, no DB password to fetch.

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.worker.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "worker"
      }
    }

    essential              = true
    readonlyRootFilesystem = false
  }])
}

# ─── Cache-bootstrap task definition (one-shot) ─────────────────────────────
# 256 CPU / 512 MB — bootstrap just runs a sieve + single Redis write.
resource "aws_ecs_task_definition" "cache_bootstrap" {
  family                   = "${var.name_prefix}-cache-bootstrap"
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
      { name = "DYNAMODB_TABLE_NAME", value = var.dynamodb_table_name },
      { name = "AWS_DEFAULT_REGION", value = var.region },
      { name = "VALKEY_ENDPOINT", value = local.valkey_endpoint },
      { name = "VALKEY_TLS", value = "true" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.bootstrap.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "bootstrap"
      }
    }

    essential              = true
    readonlyRootFilesystem = false
  }])
}

# ─── Worker service ─────────────────────────────────────────────────────────
resource "aws_ecs_service" "worker" {
  name            = "${var.name_prefix}-worker"
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

# ─── Worker autoscaling on SQS queue depth ──────────────────────────────────
resource "aws_appautoscaling_target" "worker" {
  max_capacity       = var.worker_max_count
  min_capacity       = var.worker_min_count
  resource_id        = "service/${module.ecs.cluster_name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.worker]
}

resource "aws_appautoscaling_policy" "target_tracking" {
  name               = "${var.name_prefix}-worker-sqs-depth"
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

# ─── Bootstrap one-shot (null_resource local-exec) ──────────────────────────
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
