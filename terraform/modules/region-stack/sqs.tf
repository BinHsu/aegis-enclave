# sqs.tf — async job queue for this region (ADR-0029).
#
# Queues are region-local: messages do NOT cross-replicate between regions.
# Visibility timeout = compute_budget x 1.5 so a message re-delivers if the
# worker crashes without acking.

resource "aws_sqs_queue" "primes_dlq" {
  name                      = "${var.name_prefix}-primes-dlq"
  message_retention_seconds = 1209600 # 14 days — max; keeps failed messages for analysis
  receive_wait_time_seconds = 0
  sqs_managed_sse_enabled   = true # SSE-SQS (SQS-owned key) — explicit at-rest encryption, free
}

resource "aws_sqs_queue" "primes" {
  name                       = "${var.name_prefix}-primes"
  visibility_timeout_seconds = var.sqs_visibility_timeout
  message_retention_seconds  = 86400 # 1 day
  receive_wait_time_seconds  = 20    # long-polling — reduces empty receive costs
  sqs_managed_sse_enabled    = true  # SSE-SQS (SQS-owned key) — explicit at-rest encryption, free

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.primes_dlq.arn
    maxReceiveCount     = 3
  })
}
