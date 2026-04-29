# ADR-0041: Observability backend — CloudWatch SLI + Dashboard + multi-window burn-rate alarms; AMG / AMP / Grafana Cloud deferred

## Status
Accepted (2026-04-28)

> Filename retains its original "amp-amg-not-grafana-cloud" form because the ADR's title-track question was framed as that comparison; the answered position narrowed further to "no Grafana surface in the case-study at all" once the apply-then-destroy evidence model made any live-URL dashboard moot. The Alternatives section walks the full ladder.

## Context

ADR-0003 (PoC scope, prod hygiene) explicitly scoped out an observability stack — no Prometheus, Grafana, Loki, APM, or distributed tracing. The deliverable emits structured JSON logs into CloudWatch and 6 CloudWatch metric panels via API; query path is the AWS Console (when SCP allows), CloudWatch Logs Insights for log-based questions, and `aws cloudwatch get-metric-widget-image` for evidence capture.

Two pressures shifted by the end of Phase 2.5.1:

1. **SLO instrumentation gap.** ADR-0008 stated SLO targets (RTO 15min / RPO 5min / latency / availability) but no metric was ever emitted to verify them. Reviewer asking "you say POST < 500ms p99 — show me the histogram" had no answer.

2. **Reviewer surfacability.** Phase 2.5.1 polish closed forker UX, decision documentation, and supply-chain rigor signals; observability was the remaining 🟡 axis. A reviewer reads "structured logs + chrome-sparse PNGs" and registers "they logged things" rather than "they operationally observed things".

The decision space had three live candidates as of 04/28:

- **Grafana Cloud** (third-party Grafana Labs hosted) — Free tier covers our scale; integrated Loki for logs.
- **AMP + AMG** (Amazon Managed Prometheus + Amazon Managed Grafana) — AWS-native; IAM Identity Center auth; in-VPC private connectivity.
- **CloudWatch native** (alarms + dashboard + EMF emission for SLI metrics) — already in the deliverable; no new service.

The collapse to the third option was driven by one architectural observation: the case-study evidence model is **screenshots from a 3h apply-then-destroy window, not a persistent live URL**. Any Grafana-flavour dashboard URL is destroyed before the recipient ever opens it. The "click into a templated dashboard and explore" value that distinguishes Grafana from CloudWatch Dashboards collapses to zero in a screenshot-only delivery. What survives is "what data + alerting do we ship?" — and CloudWatch can match Grafana's data + alerting capability for our SLO shape (multi-window burn rate, p99 latency, ratio metrics, composite alarms) without the perception-layer Grafana provides.

This ADR adopts the third option in the case-study deliverable. The Alternatives section preserves the AMP+AMG comparison + the Grafana Cloud comparison so a forker promoting to a persistent production deployment knows the upgrade path and the trade-offs.

## Decision

The observability backend in the case-study deliverable is **AWS-native: CloudWatch SLI metrics via EMF emission + CloudWatch Dashboard + CloudWatch alarms with multi-window burn-rate logic + optional SNS email delivery**. Concretely:

### SLI emission via EMF (Embedded Metric Format)

`src/prime_service/metrics.py` (new module) wraps structlog with the AWS EMF spec: each metric emit writes a structured JSON line to stdout that the awslogs driver ships to CloudWatch Logs, and CloudWatch Logs auto-extracts the metric into the `aegis-enclave` namespace within ~30 seconds. **No synchronous PutMetricData call** — overhead is bounded by JSON serialisation (~5-10ms per emit) and rides on the log shipping path that already exists.

Metrics emitted:

| Metric | Source | Statistic | Used by |
|---|---|---|---|
| `request_total` | API middleware (every request) | Sum (60s) | SLO denominator + dashboard volume panel |
| `request_errors_5xx` | API middleware (5xx response) | Sum (60s, 6h) | SLO numerator (server errors only) |
| `request_errors_4xx` | API middleware (4xx response) | Sum (60s) | Tracked but **not** in SLO error budget (client errors are not service faults) |
| `request_latency_ms` | API middleware (every request) | p50/p95/p99 (60s) | Latency SLO alarm + dashboard latency panel |
| `cache_hit_count` | Worker (cache hit path) | Sum (60s, 30min) | Cache hit ratio numerator + volume panel |
| `cache_miss_count` | Worker (compute path) | Sum (60s, 30min) | Cache hit ratio denominator + volume panel |
| `cache_lookup_errors` | Worker (cache get exception) | Sum (60s) | Diagnostic — non-fatal Valkey issues |
| `cache_write_errors` | Worker (cache merge exception) | Sum (60s) | Diagnostic — non-fatal Valkey issues |
| `compute_duration_ms` | Worker (compute path) | p50/p95/p99 (60s) | Compute latency SLO alarm + dashboard |
| `compute_errors{error_class}` | Worker (timeout/validation/generic) | Sum (60s) | Diagnostic — error-type breakdown |
| `poll_to_done_ms` | Worker (both paths, end of message) | p95 (60s) | End-to-end SLO (poll-to-done) |

Dimension cardinality is deliberately **bounded to zero** for SLO metrics — no `path`, no `request_id`, no `execution_id`. Path-level breakdown remains available via CloudWatch Logs Insights queries on the `request_completed` structlog event (which carries path + status_code + duration_ms in one line). The alternative of multi-dimension EMF emission was considered and rejected because alarm metric queries against multi-dimension series require `SEARCH()` expressions that flicker into INSUFFICIENT_DATA when no matching series exists.

### CloudWatch Dashboard

`aws_cloudwatch_dashboard.slo` provisions a 6-panel dashboard:

1. **Volume** — `request_total` + `cache_hit_count` + `cache_miss_count` (lines)
2. **API latency** — `request_latency_ms` p50/p95/p99 + horizontal annotation at 500ms (SLO p99 target)
3. **5xx error rate %** — `100 * (request_errors_5xx / request_total)` + horizontal annotations at 0.1% (SLO target), 0.6% (slow-burn threshold), 1.44% (fast-burn threshold)
4. **Cache hit ratio %** — `100 * (cache_hit_count / (cache_hit + cache_miss))` + horizontal annotation at 80% (SLO target)
5. **Compute duration** — `compute_duration_ms` p50/p95/p99 + horizontal annotations at 30000ms (SLO target) and 60000ms (SIGALRM hard ceiling)
6. **Alarm state strip** — live ALARM/OK/INSUFFICIENT_DATA states for all 7 case-study alarms (SLO + DLQ + composite)

The dashboard is provisioned + destroyed with the rest of the terraform composition. No manual dashboard-as-state to lose; reviewer-facing screenshots come from this dashboard during the Phase 2.5 evidence window.

### Alarms — multi-window multi-burn-rate (Google SRE Workbook canonical pattern)

Six alarms, all wired through `local.alarm_action_list`:

| Alarm | Logic | Window | Threshold |
|---|---|---|---|
| `slo_fast_burn` | 5xx error rate % over 1h | 1h | > 1.44% (14.4× SLO target) |
| `slo_slow_burn` | 5xx error rate % over 6h | 6h | > 0.6% (6× SLO target) |
| `slo_breach` (composite) | `slo_fast_burn` AND `slo_slow_burn` | composite | both ALARM |
| `latency_p99_breach` | p99 of `request_latency_ms` | 5min × 3 evaluations | > 500ms |
| `cache_hit_ratio_low` | hit / (hit + miss) % over 30min | 30min | < 80% |
| `compute_p95_breach` | p95 of `compute_duration_ms` | 5min × 3 evaluations | > 30000ms |

Plus the existing `dlq_depth` alarm from ADR-0038 (depth > 0 on the DLQ).

The composite `slo_breach` alarm is the operator-paging entry point: only fires when both fast and slow burn agree, which avoids paging on a single transient spike (fast-burn alone) while still catching real budget consumption (slow-burn alone might be too late if recovery never happens).

### Email delivery — opt-in via tfvars

`variable "alarm_email"` defaults to empty string, which sets `count = 0` on the SNS topic + subscription resources and `alarm_actions = []` on every alarm (the empty-action behaviour preserves the original ADR-0038 stance — alarms fire silently with EventBridge audit trail). Setting `alarm_email` (via `tfvars-init.sh` interactive prompt or `TF_ALARM_EMAIL` env var for CI) provisions the SNS topic, subscribes the email address, and wires every alarm's `alarm_actions` to the topic ARN.

`scripts/cloud-up.sh` end-of-flow message reads `alarm_email` back from `terraform.tfvars` and prints the literal address — "An email from 'AWS Notification - Subscription Confirmation' was sent to: `<address>`" — so the operator knows which inbox to check rather than guessing across multiple addresses.

### What's deferred to V2

| V2 item | Why deferred |
|---|---|
| **AMG dashboards-as-code** (terraform `grafana/grafana` provider + IaC dashboard JSON) | AMG itself was rejected (see Alternatives); its dashboard-as-code workflow is therefore moot. CloudWatch Dashboard is provisioned via `aws_cloudwatch_dashboard` resource — already IaC. |
| **AMP + ADOT collector** (Prometheus protocol native scrape) | EMF gives us the same metric data via a simpler emission path. AMP would matter once the application emits high-cardinality metrics (per-execution series, distribution exemplars) that EMF's `Dimensions` schema is awkward for. PoC scope doesn't reach that. |
| **Grafana Cloud Loki for log indexing** | CloudWatch Logs Insights handles our query patterns (filter by execution_id / request_id, count cache_hit events) at PoC scale. Loki's faster trace-of-many-logs query becomes valuable past ~1 GB/day log volume. |
| **AWS X-Ray distributed tracing** | Tier 3 in the original observability tiering. SQS message-attribute trace_id propagation is the non-trivial piece; ADOT collector + X-Ray is the AWS-native path. Defer until first buyer / forker-side need. |
| **SNS topic policy + cross-account / cross-region SNS** | Multi-region (ADR-0040) requires a cross-region SNS strategy. Single-region case-study composition uses the simple in-region topic. |
| **PagerDuty / Slack via AWS Chatbot** | Email is the simplest delivery channel for a case-study deliverable. Chatbot integration adds Slack workspace + chatbot config + IAM scope creep. Forker's production composition extends `alarm_actions` with their existing channel. |

## Alternatives Considered

| Candidate | Why not chosen |
|---|---|
| **AMG (Amazon Managed Grafana) with CloudWatch as data source** | The architecturally cleanest "have a Grafana surface" option for an AWS-native deployment — AMG runs in-VPC with private endpoints, uses IAM Identity Center for the SSO operators already have, and the terraform provider is first-party AWS. **But the case-study evidence model is screenshots, not a persistent live URL.** AMG's Grafana surface is destroyed at `terraform destroy` after a 3h window — the recipient receiving the case-study report PDF never sees the AMG URL functioning. The 70% perception value of "they have Grafana" survives in screenshots, but the 30% real engineering value (templated dashboards + ad-hoc query exploration) is gone. AMG also bills per active user per month ($9 editor / $5 viewer); zero in a 3h window because billing is monthly, but adds operational cost for production forkers. **The promotion path remains clean**: a forker who wants AMG provisions `aws_grafana_workspace` + `aws_grafana_workspace_role_association` + a dashboards-as-code pass via the `grafana/grafana` terraform provider. ~7-8 hours from this baseline. |
| **AMP (Amazon Managed Prometheus) for metric ingest** | AMP accepts standard Prometheus `remote_write` from any Prometheus client. The application would expose a `/metrics` endpoint via `prometheus_client` Python lib + an ADOT collector ECS sidecar would scrape it and `remote_write` to AMP. **Architecturally equivalent to EMF for our scope, with more moving parts.** EMF rides the awslogs driver (already provisioned for log shipping) and avoids a `/metrics` endpoint that would need backpressure-middleware bypass logic + private-VPC scraper plumbing. AMP becomes the right call once the application emits exemplars, histograms with custom buckets, or high-cardinality metrics that EMF's dimension model is awkward for. |
| **Grafana Cloud (third-party Grafana Labs hosted)** | Free tier (10K series + 50GB logs + 50GB traces + 3 users) is genuinely cheaper at case-study scale than AMG. Loki for logs is integrated. **Three architectural mismatches remain**: (1) workspace endpoint is internet-only (`<workspace>.grafana.net`), at odds with the private-only VPC posture (ADR-0019). (2) Auth is a separate Grafana Cloud account, not the IAM Identity Center the operators already use. (3) Terraform integration uses the external `grafana/grafana` provider, not the `aws` provider already pinned. Cumulative effect is "introduce a non-AWS dependency and re-justify it in three architectural places". The case-study screenshot evidence model also flattens Grafana Cloud's UI advantage. Rejected on architectural fit primarily; cost is a secondary factor. |
| **Self-hosted Prometheus + Grafana on ECS** | Maximum flexibility, zero vendor lock-in, lowest steady-state cost (~$0.024/h Fargate cost for the two containers). Rejected by ADR-0018 (managed-default tool selection) — owning a stateful observability stack adds the exact ops surface the calibration intentionally avoids. Self-hosted fits a deployment with an internal platform team that already runs Prometheus; aegis-enclave's "small application, EU-only, AWS-native" shape is too small for the operational owner cost. |
| **CloudWatch Dashboards only (no SLI emission, no alarms beyond DLQ)** | The lowest-effort path. **Rejected** because it doesn't close the SLI/SLO gap — the dashboard would render the existing 6 CloudWatch native metrics (RDS / ECS / SQS / ElastiCache / ALB) but not the application-level SLOs ADR-0008 names. The visualization would be present without the underlying instrumentation, leaving "show me the p99 histogram" still unanswered. |
| **Datadog / New Relic / Honeycomb** | Mature APM products covering all signal types. Rejected — cost (per-host + per-million-spans billing escalates fast), non-AWS dependency, and auth model mismatch. Right call for a sustained-traffic service with a dedicated SRE team; over-built for a 3-AZ single-region case-study with one operator. |
| **EMF emission with multi-dimension series for SLO metrics** | EMF supports multiple `Dimensions` sets per emission, so one log line can create both a per-path series and an aggregated series. This was considered and rejected for SLO alarms specifically — alarm metric queries against multi-dimension series require `SEARCH()` expressions that can return None when no matching series exists for the period, putting the alarm into INSUFFICIENT_DATA. Per-path breakdown is preserved via CloudWatch Logs Insights queries on the `request_completed` structlog event. Application-level metrics (compute duration, cache events) similarly emit zero-dimension. |
| **Pull-based scrape via ECS sidecar (Prometheus exposition)** | Application exposes `/metrics`; sidecar scrapes locally; sidecar pushes to wherever (AMP, Grafana Cloud, self-hosted Prom). Adds a sidecar container to every task definition, plus the `/metrics` HTTP route in FastAPI (and its backpressure-middleware bypass). Push-based EMF avoids both. Pull is the right call when you want application-controlled scrape interval + multi-tenant scrape parameters; we don't need either at PoC scope. |

## Consequences

- `src/prime_service/metrics.py` (new module, 29 unit tests) is the canonical SLI emission API. `emit_count` / `emit_latency_ms` / `emit_metric` cover the population. Every emit lands in the `aegis-enclave` CloudWatch namespace.
- `src/prime_service/main.py` middleware emits per-request SLI; `src/prime_service/worker.py` `handle_message` emits per-message SLI. Bootstrap doesn't emit SLI (lifecycle task, no per-request context). The structlog config in all three modules pulls `merge_contextvars` for `request_id` / `execution_id` correlation.
- `terraform/main.tf` adds: 1 conditional SNS topic + 1 conditional email subscription + 6 alarms (5 metric + 1 composite) + 1 CloudWatch Dashboard. The `local.alarm_action_list` pattern keeps every alarm's `alarm_actions` symmetric — adding a new alarm = one new resource block, no manual wiring.
- `terraform/variables.tf` adds `alarm_email` with email regex validation; default empty string.
- `scripts/tfvars-init.sh` adds an interactive prompt + batch override (`TF_ALARM_EMAIL`); empty input is the explicit way to skip SNS provisioning.
- `scripts/cloud-up.sh` end-of-flow message reads `alarm_email` from `terraform.tfvars` and prints the literal address in the SNS confirmation reminder. Empty-string alarm_email skips the entire reminder section.
- **Cost**: alarms free; CloudWatch Dashboard free; SNS first 1000 publishes/month free, then $0.50/million; EMF emission is billed as Logs ingestion which the deliverable already pays. Wed window cost impact ≈ $0.
- **Wed evidence**: dashboard panels captured via `aws cloudwatch get-metric-widget-image` API path (per-panel PNG), alarm state snapshot via `describe-alarms` (JSON), alarm-history transitions via `describe-alarm-history` (JSON), optionally a deliberate-trigger test (operator sets one alarm to ALARM via CLI → email arrives → screenshot the email + capture the alarm-history transition).
- **AWS Console UI for CloudWatch Dashboards is typically SCP-blocked** at the org level via `cloudwatch:ListMetrics` deny — observed in the case-study staging account, treated by the deployment_guide as a positive guardrail signal. The dashboard provisioning still has full value (alarms still fire; threshold annotations live in the dashboard JSON; the dashboard is reproducible IaC in `terraform/main.tf`), but the **screenshot path is API-only**, not Console-only. `scripts/cloud-evidence.sh` § 5 captures every panel via `get-metric-widget-image` so a forker working in an SCP-restricted account gets the same evidence shape. Forker working in a less-restricted account additionally gets the live Console UI for ad-hoc exploration; both paths produce the screenshot evidence the case-study report PDF attaches.
- **Reviewer signal**: PDF screenshots show p99 latency line + 500ms SLO threshold annotation, error rate line + 1.44%/0.6%/0.1% threshold annotations (multi-window burn rate visually present), cache hit ratio line + 80% threshold. A senior reviewer reads "metered SLO with multi-window burn-rate alarms" — the same signal Grafana SLO plugin would carry, in CloudWatch's UI.
- **Forker promotion paths**: (1) AMG dashboards-as-code via `grafana/grafana` provider — ~7-8h. (2) AMP for high-cardinality metrics + ADOT collector + Prometheus exposition path — ~12-15h. (3) Grafana Cloud + Loki for unified logs+metrics+traces — ~16-20h. All three can be promoted independently of each other; CloudWatch Dashboard + alarms remain the floor.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene calibration — this ADR refines what "out of scope" means: SLO instrumentation in scope; APM / distributed tracing / Grafana surface remain V2)
- ADR-0008 (reliability targets — SLO numbers this ADR finally meters)
- ADR-0018 (managed-default tool selection — "AWS managed primitive over self-host" applied to the observability layer)
- ADR-0019 (private-only VPC — CloudWatch / SNS / EventBridge are in-region AWS services consumable via VPC endpoints already provisioned, no new private-connectivity surface)
- ADR-0024 (mTLS Client VPN — operator reaches CloudWatch Console and AMG (if promoted) over the same VPN that reaches the ALB)
- ADR-0038 (DLQ alarm + manual triage — same pattern: alarm exists, action is opt-in. This ADR generalises the alarm_action_list local to all alarms)
- ADR-0040 (multi-region production target — when implemented, alarms are per-region; cross-region SNS aggregation remains a forker concern)
