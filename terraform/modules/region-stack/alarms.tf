# alarms.tf — alerting backbone for this region: SNS topic, SLO alarms,
# composite alarm, and the SLO dashboard (ADR-0038 + ADR-0041).
#
# ADR-0041: alarms always exist + always emit state changes to EventBridge
# (audit trail). Email delivery is opt-in via var.alarm_email — empty string
# leaves alarm_actions = [] and the deliverable ships with no unsolicited mail.

resource "aws_sns_topic" "alarms" {
  count = var.alarm_email != "" ? 1 : 0
  name  = "${var.name_prefix}-alarms"
}

resource "aws_sns_topic_subscription" "alarms_email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# Helper local — every alarm references this for alarm_actions / ok_actions.
locals {
  alarm_action_list = try([aws_sns_topic.alarms[0].arn], [])
}

# ─── DLQ depth alarm — operator-actionable signal (ADR-0038) ────────────────
resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${var.name_prefix}-primes-dlq-depth"
  alarm_description   = "DLQ has at least one message - worker exhausted maxReceiveCount=3 retries on main queue. Triage with scripts/dlq-triage.sh per ADR-0038."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60 # 1-minute granularity
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching" # zero-depth = OK, missing data = OK

  dimensions = {
    QueueName = aws_sqs_queue.primes_dlq.name
  }

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# ─── SLO alarms (ADR-0041) ──────────────────────────────────────────────────
# SLI metrics emitted via EMF from src/prime_service/{main,worker,metrics}.py.

# Fast burn — 1h window, 14.4x SLO threshold.
resource "aws_cloudwatch_metric_alarm" "slo_fast_burn" {
  alarm_name          = "${var.name_prefix}-slo-fast-burn"
  alarm_description   = "SLO fast burn: 5xx error rate > 1.44% over 1h (14.4x the 0.1% target). Consumes 2% of 30-day error budget if sustained."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1.44
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate_pct"
    expression  = "100 * (FILL(m_errors, 0) / m_total)"
    label       = "5xx error rate %"
    return_data = true
  }
  metric_query {
    id = "m_errors"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "request_errors_5xx"
      period      = 3600
      stat        = "Sum"
    }
  }
  metric_query {
    id = "m_total"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "request_total"
      period      = 3600
      stat        = "Sum"
    }
  }

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# Slow burn — 6h window, 6x SLO threshold.
resource "aws_cloudwatch_metric_alarm" "slo_slow_burn" {
  alarm_name          = "${var.name_prefix}-slo-slow-burn"
  alarm_description   = "SLO slow burn: 5xx error rate > 0.6% over 6h (6x the 0.1% target). Consumes 5% of 30-day error budget if sustained."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0.6
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate_pct"
    expression  = "100 * (FILL(m_errors, 0) / m_total)"
    label       = "5xx error rate %"
    return_data = true
  }
  metric_query {
    id = "m_errors"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "request_errors_5xx"
      period      = 21600 # 6h
      stat        = "Sum"
    }
  }
  metric_query {
    id = "m_total"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "request_total"
      period      = 21600
      stat        = "Sum"
    }
  }

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# Composite — only page when BOTH fast AND slow burn fire.
resource "aws_cloudwatch_composite_alarm" "slo_breach" {
  alarm_name        = "${var.name_prefix}-slo-breach"
  alarm_description = "Confirmed SLO breach: fast-burn AND slow-burn both ALARM. Real error budget consumption past 7%; operator action expected."
  alarm_rule        = "ALARM(${aws_cloudwatch_metric_alarm.slo_fast_burn.alarm_name}) AND ALARM(${aws_cloudwatch_metric_alarm.slo_slow_burn.alarm_name})"

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# Latency SLO — POST 202 should return < 500ms p99.
resource "aws_cloudwatch_metric_alarm" "latency_p99_breach" {
  alarm_name          = "${var.name_prefix}-latency-p99-breach"
  alarm_description   = "API request latency p99 > 500ms sustained for 15 minutes. Per ADR-0008 SLO."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3 # 3 x 5min periods -> 15min sustained
  threshold           = 500
  treat_missing_data  = "notBreaching"

  metric_name        = "request_latency_ms"
  namespace          = "aegis-enclave"
  period             = 300
  extended_statistic = "p99"

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# Cache hit ratio SLO.
resource "aws_cloudwatch_metric_alarm" "cache_hit_ratio_low" {
  alarm_name          = "${var.name_prefix}-cache-hit-ratio-low"
  alarm_description   = "Cache hit ratio < 80% over 30min sustained. Suggests Valkey unhealthy, bootstrap didn't seed, or range-coalescing broken."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = 80
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "hit_ratio_pct"
    expression  = "100 * (FILL(m_hit, 0) / (FILL(m_hit, 0) + FILL(m_miss, 0)))"
    label       = "cache hit ratio %"
    return_data = true
  }
  metric_query {
    id = "m_hit"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "cache_hit_count"
      period      = 1800
      stat        = "Sum"
    }
  }
  metric_query {
    id = "m_miss"
    metric {
      namespace   = "aegis-enclave"
      metric_name = "cache_miss_count"
      period      = 1800
      stat        = "Sum"
    }
  }

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# Compute path latency SLO.
resource "aws_cloudwatch_metric_alarm" "compute_p95_breach" {
  alarm_name          = "${var.name_prefix}-compute-p95-breach"
  alarm_description   = "Worker compute_duration_ms p95 > 30s sustained 15min. Half the SIGALRM 60s ceiling - investigate range distribution + CPU."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 30000
  treat_missing_data  = "notBreaching"

  metric_name        = "compute_duration_ms"
  namespace          = "aegis-enclave"
  period             = 300
  extended_statistic = "p95"

  alarm_actions = local.alarm_action_list
  ok_actions    = local.alarm_action_list
}

# ─── SLO dashboard — single-pane visualization ──────────────────────────────
resource "aws_cloudwatch_dashboard" "slo" {
  dashboard_name = "${var.name_prefix}-slo"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title = "Request volume + cache breakdown"
          metrics = [
            ["aegis-enclave", "request_total", { stat = "Sum", label = "Total requests" }],
            [".", "cache_hit_count", { stat = "Sum", label = "Cache hits" }],
            [".", "cache_miss_count", { stat = "Sum", label = "Cache misses" }],
          ]
          period  = 60
          region  = var.region
          view    = "timeSeries"
          stacked = false
          yAxis   = { left = { min = 0, label = "requests / minute" } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title = "API request latency (SLO target: p99 < 500ms)"
          metrics = [
            ["aegis-enclave", "request_latency_ms", { stat = "p50", label = "p50" }],
            [".", ".", { stat = "p95", label = "p95" }],
            [".", ".", { stat = "p99", label = "p99" }],
          ]
          period = 60
          region = var.region
          view   = "timeSeries"
          yAxis  = { left = { min = 0, label = "ms" } }
          annotations = {
            horizontal = [
              { value = 500, label = "SLO p99 target", color = "#d62728" },
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "5xx error rate % (SLO target < 0.1%)"
          metrics = [
            [
              {
                expression = "100 * (FILL(m_errors, 0) / m_total)"
                label      = "5xx error rate %"
                id         = "rate"
              }
            ],
            ["aegis-enclave", "request_errors_5xx", { id = "m_errors", visible = false, stat = "Sum" }],
            [".", "request_total", { id = "m_total", visible = false, stat = "Sum" }],
          ]
          period = 60
          region = var.region
          view   = "timeSeries"
          yAxis  = { left = { min = 0, label = "% errors" } }
          annotations = {
            horizontal = [
              { value = 0.1, label = "SLO target 0.1%", color = "#2ca02c" },
              { value = 0.6, label = "Slow-burn threshold (6x SLO, 6h window)", color = "#ff7f0e" },
              { value = 1.44, label = "Fast-burn threshold (14.4x SLO, 1h window)", color = "#d62728" },
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Cache hit ratio % (SLO target >= 80%)"
          metrics = [
            [
              {
                expression = "100 * (FILL(m_hit, 0) / (FILL(m_hit, 0) + FILL(m_miss, 0)))"
                label      = "cache hit ratio %"
                id         = "ratio"
              }
            ],
            ["aegis-enclave", "cache_hit_count", { id = "m_hit", visible = false, stat = "Sum" }],
            [".", "cache_miss_count", { id = "m_miss", visible = false, stat = "Sum" }],
          ]
          period = 60
          region = var.region
          view   = "timeSeries"
          yAxis  = { left = { min = 0, max = 100, label = "% hit" } }
          annotations = {
            horizontal = [
              { value = 80, label = "SLO target 80%", color = "#2ca02c" },
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "Worker compute duration (SIGALRM ceiling 60000ms)"
          metrics = [
            ["aegis-enclave", "compute_duration_ms", { stat = "p50", label = "p50" }],
            [".", ".", { stat = "p95", label = "p95" }],
            [".", ".", { stat = "p99", label = "p99" }],
          ]
          period = 60
          region = var.region
          view   = "timeSeries"
          yAxis  = { left = { min = 0, label = "ms" } }
          annotations = {
            horizontal = [
              { value = 30000, label = "SLO target p95 < 30s", color = "#ff7f0e" },
              { value = 60000, label = "SIGALRM hard ceiling", color = "#d62728" },
            ]
          }
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "SLO alarm states"
          alarms = [
            aws_cloudwatch_metric_alarm.slo_fast_burn.arn,
            aws_cloudwatch_metric_alarm.slo_slow_burn.arn,
            aws_cloudwatch_composite_alarm.slo_breach.arn,
            aws_cloudwatch_metric_alarm.latency_p99_breach.arn,
            aws_cloudwatch_metric_alarm.cache_hit_ratio_low.arn,
            aws_cloudwatch_metric_alarm.compute_p95_breach.arn,
            aws_cloudwatch_metric_alarm.dlq_depth.arn,
          ]
        }
      },
    ]
  })
}
