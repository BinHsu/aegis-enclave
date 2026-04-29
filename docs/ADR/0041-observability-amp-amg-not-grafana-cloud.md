# ADR-0041: Observability backend — CloudWatch SLI emission + multi-window burn-rate alarms

## Status
Accepted (2026-04-28)

This case-study uses CloudWatch native as the cleanest path to surface SLO indicators within the apply-then-destroy verification window — minimal moving parts, no third-party setup, screenshot-grade evidence captured via `get-metric-widget-image` API.

For sustained production use, the recommended observability stack is **Grafana Cloud + Loki + OpenTelemetry** — the vendor-neutral, multi-cloud-portable triad that delivers the best observability completeness for a long-running system. See `production_adoption.md` § Observability at production scale for the migration path.

The decision below scopes only the case-study deliverable; the production extension lives in production_adoption.md.

## Context

ADR-0008's SLO targets (RTO 15 min / RPO 5 min / latency / availability / cache hit ratio) need to be observable, not just stated. SLO instrumentation requires:

1. **SLI emission** — application metrics that operationalise the SLO numerator/denominator.
2. **Visualisation** — a dashboard the operator and reviewer can read.
3. **Alerting** — multi-window burn-rate alarms (Google SRE Workbook canonical pattern) that fire when error budget consumption is running ahead.
4. **Delivery** — a path from alarm to a human (email / paging / chat).

The case-study evidence model is screenshots from a bounded apply-then-destroy verification window — not a persistent live URL. Within that window, "data + alarms" is the value delivered; "click into a templated dashboard and explore" is value that collapses to zero in a screenshot-only delivery.

## Decision

The observability backend is **AWS-native: CloudWatch SLI metrics via EMF emission + CloudWatch Dashboard + CloudWatch alarms with multi-window burn-rate logic + optional SNS email delivery.**

### SLI emission via EMF (Embedded Metric Format)

`src/prime_service/metrics.py` wraps structlog with the AWS EMF spec: each metric emit writes a structured JSON line to stdout that the awslogs driver ships to CloudWatch Logs, and CloudWatch Logs auto-extracts the metric into the `aegis-enclave` namespace within ~30 s. **No synchronous PutMetricData call** — overhead bounded by JSON serialisation (~5–10 ms per emit), riding on the existing log shipping path.

Metrics emitted:

| Metric | Source | Statistic | Used by |
|---|---|---|---|
| `request_total` | API middleware (every request) | Sum (60s) | SLO denominator + dashboard volume panel |
| `request_errors_5xx` | API middleware (5xx response) | Sum (60s, 6h) | SLO numerator (server errors only) |
| `request_errors_4xx` | API middleware (4xx response) | Sum (60s) | Tracked but not in SLO error budget (client errors are not service faults) |
| `request_latency_ms` | API middleware (every request) | p50/p95/p99 (60s) | Latency SLO alarm + dashboard latency panel |
| `cache_hit_count` | Worker (cache hit path) | Sum (60s, 30min) | Cache hit ratio numerator + volume panel |
| `cache_miss_count` | Worker (compute path) | Sum (60s, 30min) | Cache hit ratio denominator + volume panel |
| `cache_lookup_errors` | Worker (cache get exception) | Sum (60s) | Diagnostic — non-fatal Valkey issues |
| `cache_write_errors` | Worker (cache merge exception) | Sum (60s) | Diagnostic — non-fatal Valkey issues |
| `compute_duration_ms` | Worker (compute path) | p50/p95/p99 (60s) | Compute latency SLO alarm + dashboard |
| `compute_errors{error_class}` | Worker (timeout/validation/generic) | Sum (60s) | Diagnostic — error-type breakdown |
| `poll_to_done_ms` | Worker (both paths, end of message) | p95 (60s) | End-to-end SLO (poll-to-done) |

Dimension cardinality is **zero** for SLO metrics — no `path`, no `request_id`, no `execution_id`. Path-level breakdown remains available via CloudWatch Logs Insights queries on the `request_completed` structlog event (which carries path + status_code + duration_ms in one line).

### CloudWatch Dashboard

`aws_cloudwatch_dashboard.slo` — a 6-panel dashboard:

1. **Volume** — `request_total` + `cache_hit_count` + `cache_miss_count` (lines)
2. **API latency** — `request_latency_ms` p50/p95/p99 + horizontal annotation at 500 ms (SLO p99 target)
3. **5xx error rate %** — `100 * (request_errors_5xx / request_total)` + horizontal annotations at 0.1% (SLO target), 0.6% (slow-burn threshold), 1.44% (fast-burn threshold)
4. **Cache hit ratio %** — `100 * (cache_hit / (cache_hit + cache_miss))` + horizontal annotation at 80% (SLO target)
5. **Compute duration** — `compute_duration_ms` p50/p95/p99 + horizontal annotations at 30000 ms (SLO target) and 60000 ms (SIGALRM hard ceiling)
6. **Alarm state strip** — live ALARM/OK/INSUFFICIENT_DATA states for all alarms

Provisioned + destroyed with the rest of the terraform composition. Reviewer-facing screenshots come from this dashboard during the verification window.

### Alarms — multi-window multi-burn-rate

Six alarms, all wired through `local.alarm_action_list`:

| Alarm | Logic | Window | Threshold |
|---|---|---|---|
| `slo_fast_burn` | 5xx error rate % over 1h | 1h | > 1.44% (14.4× SLO target) |
| `slo_slow_burn` | 5xx error rate % over 6h | 6h | > 0.6% (6× SLO target) |
| `slo_breach` (composite) | `slo_fast_burn` AND `slo_slow_burn` | composite | both ALARM |
| `latency_p99_breach` | p99 of `request_latency_ms` | 5min × 3 evaluations | > 500 ms |
| `cache_hit_ratio_low` | hit / (hit + miss) % over 30 min | 30 min | < 80% |
| `compute_p95_breach` | p95 of `compute_duration_ms` | 5 min × 3 evaluations | > 30000 ms |

Plus the existing `dlq_depth` alarm from ADR-0038 (depth > 0 on the DLQ).

The composite `slo_breach` is the operator-paging entry point: only fires when both fast and slow burn agree, avoiding pages on transient spikes (fast-burn alone) while still catching real budget consumption.

### Email delivery — opt-in

`variable "alarm_email"` defaults to empty string, which sets `count = 0` on the SNS topic + subscription resources and `alarm_actions = []` on every alarm (alarms still fire silently with EventBridge audit trail). Setting `alarm_email` provisions the SNS topic, subscribes the email, and wires every alarm's `alarm_actions` to the topic ARN.

## Alternatives Considered

| Alternative | Industry context |
|---|---|
| **Synchronous `cloudwatch:PutMetricData`** | Adds 5–50 ms network latency per request. EMF-via-stdout avoids this entirely by riding the awslogs driver. |
| **Single-window burn-rate** (no fast/slow composite) | Less robust per Google SRE Workbook — single-window is either too noisy (short window) or too lagged (long window). Multi-window catches both. |
| **Multi-dimension EMF series** (per-path, per-execution) | Cardinality + alarm `SEARCH()` flicker into INSUFFICIENT_DATA. SLO metrics emit zero-dimension; per-path detail stays in Logs Insights. |
| **Pull-based Prometheus scrape from sidecar** | Adds sidecar container + `/metrics` endpoint + middleware bypass logic. EMF avoids this entire surface. |

## Consequences

- `src/prime_service/metrics.py` is the canonical SLI emission API.
- `terraform/main.tf` adds: 1 conditional SNS topic + 1 conditional email subscription + 6 alarms (5 metric + 1 composite) + 1 CloudWatch Dashboard. The `local.alarm_action_list` pattern keeps every alarm's `alarm_actions` symmetric.
- **Cost** at the verification-window scale: alarms free, dashboard free, SNS first 1000 publishes/month free, EMF emission billed as Logs ingestion (already paid). Window cost impact ≈ $0.
- **Evidence path**: dashboard panels captured via `aws cloudwatch get-metric-widget-image` API path (per-panel PNG). AWS Console for CloudWatch Dashboards is typically SCP-blocked at the org level via `cloudwatch:ListMetrics` deny — observed in the staging account, treated as a positive guardrail signal. The screenshot path is API-only, not Console-only; `scripts/cloud-evidence.sh` captures every panel via `get-metric-widget-image` so a forker working in an SCP-restricted account gets the same evidence shape.
- **Reviewer signal**: PDF screenshots show p99 latency line + 500 ms SLO threshold annotation, error rate line + 1.44%/0.6%/0.1% threshold annotations (multi-window burn rate visually present), cache hit ratio line + 80% threshold. A senior reviewer reads "metered SLO with multi-window burn-rate alarms" — the same signal Grafana SLO plugin would carry, in CloudWatch's UI.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene calibration — SLO instrumentation in scope)
- ADR-0008 (reliability targets — SLO numbers this ADR meters)
- ADR-0019 (private-only VPC — CloudWatch / SNS / EventBridge consumable via VPC endpoints already provisioned)
- ADR-0038 (DLQ alarm + manual triage — same pattern: alarm exists, action is opt-in. This ADR generalises the alarm_action_list local to all alarms)
- ADR-0042 (data store — DynamoDB Global Tables — SLI emission unchanged across data-layer choice)
