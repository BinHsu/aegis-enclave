# iam.tf — IAM role for the ECS tasks (worker + bootstrap) in this region.
#
# ADR-0042: DDB perms, not RDS. Permissions:
#   - SQS: receive / delete / send / get-attributes on the regional queues
#   - DynamoDB: GetItem / PutItem / UpdateItem / Query / DescribeTable scoped
#     to the executions table (single-table model)
#   - ECR + logs: standard Fargate task-role managed-policy attachments
# Valkey needs no IAM — it is authenticated by network isolation (SG) only.

locals {
  # DynamoDB Global Tables expose one logical table; the IAM resource ARN per
  # region follows arn:aws:dynamodb:<region>:<account>:table/<name>. Scoping to
  # this region's replica ARN keeps the policy least-privilege per region.
  dynamodb_region_arn = "arn:aws:dynamodb:${var.region}:${var.account_id}:table/${var.dynamodb_table_name}"
}

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
  name               = "${var.name_prefix}-worker"
  assume_role_policy = data.aws_iam_policy_document.worker_assume.json
}

data "aws_iam_policy_document" "worker_policy" {
  # SQS: receive + ack + enqueue + depth-check on the regional queues.
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
      aws_sqs_queue.primes.arn,
      aws_sqs_queue.primes_dlq.arn,
    ]
  }

  # ADR-0042: DynamoDB executions table — read + write + describe. Scoped to
  # this region's table ARN + its /index/* GSI sub-resources (glob covers a
  # future GSI without policy churn — the recommended idiom, not a wildcard).
  statement {
    sid = "DynamoDBExecutions"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:DescribeTable",
    ]
    # tfsec false positive: not a broad wildcard — scoped to this one table's
    # own GSI sub-resources (<table-arn>/index/*), the recommended idiom.
    #tfsec:ignore:aws-iam-no-policy-wildcards
    resources = [
      var.dynamodb_table_arn,
      "${var.dynamodb_table_arn}/index/*",
      local.dynamodb_region_arn,
      "${local.dynamodb_region_arn}/index/*",
    ]
  }

  # ADR-0048: result store. ECS tasks need Get + Put on objects under
  # this region's independent results bucket. A cross-region miss is
  # regenerated locally (recompute-on-miss, ADR-0049) — Put covers that too.
  # Scoped to bucket-relative keys only — no DeleteObject (lifecycle policy
  # handles deletion); no PutBucket* (terraform owns those).
  # tfsec false positive: '<bucket>/*' is the canonical and minimum scope
  # for "all objects in this one bucket"; same idiom as the DDB statement
  # above and as recommended by AWS S3 IAM examples.
  #tfsec:ignore:aws-iam-no-policy-wildcards
  statement {
    sid = "S3ResultsRW"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.results.arn}/*"]
  }

  # ADR-0048: explicit bucket-level ListBucket is needed when the SDK
  # checks for existence (HeadObject paths sometimes synthesise a ListBucket
  # under the hood, and Get/PutObject's 403 vs 404 disambiguation needs it).
  statement {
    sid       = "S3ResultsList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.results.arn]
  }
}

resource "aws_iam_role_policy" "worker_inline" {
  name   = "${var.name_prefix}-worker-inline"
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
