#!/usr/bin/env bash
# cloud-evidence.sh — capture Phase 2.5 evidence artifacts before teardown.
#
# Per memory feedback_phase25_screenshot_evidence.md: 'terraform destroy' is
# irreversible — every dashboard / log line / handshake must be captured BEFORE
# 'make cloud-down'. This script automates the API-fetchable subset:
#
#   - 6 CloudWatch metric widget PNGs (SQS / ECS / ElastiCache / ALB / RDS)
#   - Worker CloudWatch log excerpts (last hour)
#   - Bootstrap task CloudWatch log excerpts (idempotency proof)
#   - terraform output (state-as-evidence)
#   - summary.md stub for browser-side screenshots + manual notes
#
# Output layout:
#   evidence/<UTC-timestamp>/
#     metrics/01-sqs-visible.png
#     metrics/02-ecs-desired-count.png
#     metrics/03-elasticache-bytes.png
#     metrics/04-elasticache-ecpu.png
#     metrics/05-alb-target-response-time.png
#     metrics/06-rds-cpu.png
#     logs/worker.log
#     logs/bootstrap.log
#     terraform-output.json
#     summary.md
#
# Note: aws cloudwatch get-metric-widget-image returns sparse-chrome PNGs
# (no titles by default — we set titles in the metric-widget JSON). For
# reviewer-grade visuals (browser screenshots), supplement with manual capture.
# This script's PNGs are baseline / machine-readable; manual screenshots
# preserve the dashboard chrome reviewers expect.
#
# Exit codes:
#   0 — captured what was available (some artifacts may be missing if
#       prerequisite resources don't exist yet; missing is logged not fatal)
#   1 — pre-flight failed
#   2 — terraform state missing (run cloud-up first)

set -euo pipefail

if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    readonly RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m'
    readonly BLUE=$'\033[34m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi
ok()      { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}⚠${RESET} %s\n" "$*" >&2; }
fail()    { printf "${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }
info()    { printf "${BLUE}→${RESET} %s\n" "$*"; }
section() { printf "\n${BOLD}── %s ──${RESET}\n" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR="$REPO_ROOT/evidence/$TS"
mkdir -p "$EVIDENCE_DIR/metrics" "$EVIDENCE_DIR/logs"

section "aegis-enclave — Phase 2.5 evidence capture"
echo "Output: $EVIDENCE_DIR"

# ─── Pre-flight ──────────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1       || fail "aws CLI not found"
command -v terraform >/dev/null 2>&1 || fail "terraform not found"
command -v jq >/dev/null 2>&1        || fail "jq not found"
command -v base64 >/dev/null 2>&1    || fail "base64 not found"

CALLER_JSON=$(aws sts get-caller-identity 2>&1) \
    || fail "AWS auth failed (check AWS_PROFILE / aws sso login)"
# Use jq for robust JSON parsing (we already require jq above) instead of grep+sed
# regexes that break on whitespace variants in the JSON output.
ACCOUNT_ID=$(echo "$CALLER_JSON" | jq -r '.Account // "?"' 2>/dev/null || echo "?")
ARN=$(echo "$CALLER_JSON" | jq -r '.Arn // "?"' 2>/dev/null || echo "?")

REGION=$(grep -E '^region[[:space:]]*=' "$TF_DIR/terraform.tfvars" 2>/dev/null \
         | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
REGION="${REGION:-eu-central-1}"

(cd "$TF_DIR" && terraform state list 2>/dev/null | head -1 >/dev/null) \
    || fail "no terraform state — run cloud-up first (exit 2)"

ok "AWS account: $ACCOUNT_ID  /  region: $REGION"

# Helper: capture a metric widget PNG. Args: $1 = filename, $2 = widget JSON.
capture_metric() {
    local fname="$1" widget="$2"
    local out="$EVIDENCE_DIR/metrics/$fname"
    if aws cloudwatch get-metric-widget-image --region "$REGION" \
         --metric-widget "$widget" --output text --query 'MetricWidgetImage' 2>/dev/null \
         | base64 -d > "$out" 2>/dev/null; then
        if [[ -s "$out" ]]; then
            ok "metric: $fname ($(wc -c <"$out" | tr -d ' ') bytes)"
        else
            rm -f "$out"
            warn "metric: $fname empty — resource may not exist yet"
        fi
    else
        warn "metric: $fname capture failed — resource may not exist yet"
    fi
}

# ─── 1. CloudWatch metric widgets ─────────────────────────────────────────
section "1/6 — CloudWatch metric widgets (AWS-native services)"

# Resolve resource identifiers DIRECTLY from terraform outputs (added in
# outputs.tf). Each output is the bare identifier CloudWatch expects in the
# corresponding metric dimension. Reading from outputs (rather than
# reverse-engineering from ARNs / DNS strings) avoids the parsing bugs that
# previously made 5/6 widgets empty:
#   - RDS used hardcoded "aegis-enclave" but actual identifier was "aegis-enclave-pg"
#   - ElastiCache Serverless uses CacheName, NOT CacheClusterId
#   - ALB needs "app/<name>/<id>" suffix, not the DNS-stripped name
SQS_NAME=$(cd "$TF_DIR" && terraform output -raw sqs_primes_name 2>/dev/null || echo "")
WORKER_SVC=$(cd "$TF_DIR" && terraform output -raw worker_service_name 2>/dev/null || echo "")
WORKER_CLUSTER=$(cd "$TF_DIR" && terraform output -raw ecs_cluster_name 2>/dev/null || echo "")
VALKEY_NAME=$(cd "$TF_DIR" && terraform output -raw valkey_cache_name 2>/dev/null || echo "")
ALB_ARN_SUFFIX=$(cd "$TF_DIR" && terraform output -raw alb_arn_suffix 2>/dev/null || echo "")
TG_ARN_SUFFIX=$(cd "$TF_DIR" && terraform output -raw alb_target_group_arn_suffix 2>/dev/null || echo "")
RDS_ID=$(cd "$TF_DIR" && terraform output -raw rds_instance_identifier 2>/dev/null || echo "")

info "Resolved dimensions:"
info "  SQS QueueName:                 ${SQS_NAME:-MISSING}"
info "  ECS ClusterName:               ${WORKER_CLUSTER:-MISSING}"
info "  ECS ServiceName (worker):      ${WORKER_SVC:-MISSING}"
info "  ElastiCache CacheName:         ${VALKEY_NAME:-MISSING}"
info "  ALB LoadBalancer arn_suffix:   ${ALB_ARN_SUFFIX:-MISSING}"
info "  ALB TargetGroup arn_suffix:    ${TG_ARN_SUFFIX:-MISSING}"
info "  RDS DBInstanceIdentifier:      ${RDS_ID:-MISSING}"

# Pre-flight discovery: list metrics that ACTUALLY exist for each namespace.
# Helps debug empty widgets — if list-metrics returns nothing for a namespace,
# the resource hasn't emitted metrics yet (insufficient time / no traffic),
# distinct from a wrong-dimension bug.
section "2/6 — Discovery dry-run (list-metrics per namespace)"
for ns in AWS/SQS AWS/ECS AWS/ElastiCache AWS/ApplicationELB AWS/RDS; do
    count=$(aws cloudwatch list-metrics --region "$REGION" --namespace "$ns" \
              --query 'Metrics | length(@)' --output text 2>/dev/null || echo "?")
    if [[ "$count" == "0" ]] || [[ "$count" == "?" ]]; then
        warn "$ns: $count metrics published yet (resource may need warm-up traffic)"
    else
        ok "$ns: $count metrics published"
    fi
done

# 01: SQS visible messages
section "3/6 — Capture metric widgets"
if [[ -n "$SQS_NAME" ]]; then
    capture_metric "01-sqs-visible.png" '{
      "metrics":[["AWS/SQS","ApproximateNumberOfMessagesVisible","QueueName","'"$SQS_NAME"'",{"label":"visible"}]],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"SQS '"$SQS_NAME"' — ApproximateNumberOfMessagesVisible","yAxis":{"left":{"min":0}}}'
else
    warn "skip 01: sqs_primes_name output missing"
fi

# 02: ECS Worker CPU + Memory utilization
if [[ -n "$WORKER_SVC" && -n "$WORKER_CLUSTER" ]]; then
    capture_metric "02-ecs-worker-utilization.png" '{
      "metrics":[
        ["AWS/ECS","CPUUtilization","ServiceName","'"$WORKER_SVC"'","ClusterName","'"$WORKER_CLUSTER"'",{"label":"CPU%"}],
        [".","MemoryUtilization",".","'"$WORKER_SVC"'",".","'"$WORKER_CLUSTER"'",{"label":"Mem%"}]
      ],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"ECS Worker '"$WORKER_SVC"' — CPU + Memory Utilization"}'
else
    warn "skip 02: ecs_cluster_name / worker_service_name output missing"
fi

# 03: ElastiCache Serverless BytesUsedForCache (uses CacheName, NOT CacheClusterId)
if [[ -n "$VALKEY_NAME" ]]; then
    capture_metric "03-elasticache-bytes.png" '{
      "metrics":[["AWS/ElastiCache","BytesUsedForCache","CacheName","'"$VALKEY_NAME"'"]],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"ElastiCache Serverless '"$VALKEY_NAME"' — BytesUsedForCache"}'

    # 04: ElastiCache ProcessingUnits (Serverless-specific metric, CacheName dim)
    capture_metric "04-elasticache-ecpu.png" '{
      "metrics":[["AWS/ElastiCache","ElastiCacheProcessingUnits","CacheName","'"$VALKEY_NAME"'"]],
      "period":60,"stat":"Sum","width":1024,"height":400,
      "title":"ElastiCache Serverless '"$VALKEY_NAME"' — ProcessingUnits (eCPU)"}'
else
    warn "skip 03 + 04: valkey_cache_name output missing"
fi

# 05: ALB TargetResponseTime — needs both LoadBalancer + TargetGroup arn suffixes
if [[ -n "$ALB_ARN_SUFFIX" && -n "$TG_ARN_SUFFIX" ]]; then
    capture_metric "05-alb-target-response-time.png" '{
      "metrics":[
        ["AWS/ApplicationELB","TargetResponseTime","LoadBalancer","'"$ALB_ARN_SUFFIX"'","TargetGroup","'"$TG_ARN_SUFFIX"'",{"label":"target ms"}],
        [".","RequestCount",".",".",".",".",{"label":"requests","stat":"Sum","yAxis":"right"}]
      ],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"ALB — TargetResponseTime + RequestCount"}'
else
    warn "skip 05: alb_arn_suffix / alb_target_group_arn_suffix output missing"
fi

# 06: RDS CPU (uses DBInstanceIdentifier from terraform output, not hardcoded)
if [[ -n "$RDS_ID" ]]; then
    capture_metric "06-rds-cpu.png" '{
      "metrics":[
        ["AWS/RDS","CPUUtilization","DBInstanceIdentifier","'"$RDS_ID"'",{"label":"CPU%"}],
        [".","DatabaseConnections",".","'"$RDS_ID"'",{"label":"connections","yAxis":"right"}]
      ],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"RDS '"$RDS_ID"' — CPU + Connections"}'
else
    warn "skip 06: rds_instance_identifier output missing"
fi

# ─── 4. CloudWatch log excerpts + cache-hit ground-truth counters ─────────
section "4/6 — CloudWatch log excerpts + cache_hit/compute_done ground truth"
START_MS=$(( ($(date +%s) - 3600) * 1000 ))

# Worker logs — full excerpt for forensic browsing
WORKER_LG="/ecs/aegis-enclave-worker"
if aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$WORKER_LG" \
     --query 'logGroups[0].logGroupName' --output text 2>/dev/null \
     | grep -q "$WORKER_LG"; then
    aws logs filter-log-events --region "$REGION" \
        --log-group-name "$WORKER_LG" \
        --start-time "$START_MS" \
        --output text \
        --query 'events[*].[timestamp,message]' \
        > "$EVIDENCE_DIR/logs/worker.log" 2>/dev/null \
        && ok "worker logs: $(wc -l <"$EVIDENCE_DIR/logs/worker.log" | tr -d ' ') lines" \
        || warn "worker log fetch failed"

    # Cache assertion ground truth — count cache_hit vs compute_done events.
    # cloud-smoke.sh references this as the authoritative cache verification
    # (smoke timer is wall-clock + network jitter; worker log is structlog
    # event stream from inside the worker process). With the new 7-step smoke
    # we expect ≥1 of each in a 5-min window after smoke runs.
    SHORT_START_MS=$(( ($(date +%s) - 600) * 1000 ))  # last 10 min
    HIT_COUNT=$(aws logs filter-log-events --region "$REGION" \
                  --log-group-name "$WORKER_LG" \
                  --start-time "$SHORT_START_MS" \
                  --filter-pattern '"cache_hit"' \
                  --query 'events | length(@)' --output text 2>/dev/null || echo "?")
    COMPUTE_COUNT=$(aws logs filter-log-events --region "$REGION" \
                      --log-group-name "$WORKER_LG" \
                      --start-time "$SHORT_START_MS" \
                      --filter-pattern '"compute_done"' \
                      --query 'events | length(@)' --output text 2>/dev/null || echo "?")
    ok "worker cache events (last 10min): cache_hit=$HIT_COUNT  compute_done=$COMPUTE_COUNT"
    echo "cache_hit_count=$HIT_COUNT" > "$EVIDENCE_DIR/logs/worker-cache-counters.txt"
    echo "compute_done_count=$COMPUTE_COUNT" >> "$EVIDENCE_DIR/logs/worker-cache-counters.txt"
    if [[ "$HIT_COUNT" == "0" ]]; then
        warn "0 cache_hit events — either bootstrap didn't seed, find_covering didn't match,"
        warn "or smoke wasn't run within the last 10 min. Check bootstrap.log + worker.log."
    fi
else
    warn "log group $WORKER_LG not found (worker may not have logged yet)"
fi

# Bootstrap logs — proves schema migration + cache pre-warm completed
BOOT_LG="/ecs/aegis-enclave-bootstrap"
if aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$BOOT_LG" \
     --query 'logGroups[0].logGroupName' --output text 2>/dev/null \
     | grep -q "$BOOT_LG"; then
    aws logs filter-log-events --region "$REGION" \
        --log-group-name "$BOOT_LG" \
        --start-time "$START_MS" \
        --output text \
        --query 'events[*].[timestamp,message]' \
        > "$EVIDENCE_DIR/logs/bootstrap.log" 2>/dev/null \
        && ok "bootstrap logs: $(wc -l <"$EVIDENCE_DIR/logs/bootstrap.log" | tr -d ' ') lines" \
        || warn "bootstrap log fetch failed"

    # Bootstrap idempotency proof — count schema_ensured + bootstrap_done/skip
    SCHEMA_COUNT=$(grep -c '"schema_ensured"' "$EVIDENCE_DIR/logs/bootstrap.log" 2>/dev/null || echo "0")
    BOOT_DONE=$(grep -c '"bootstrap_done"' "$EVIDENCE_DIR/logs/bootstrap.log" 2>/dev/null || echo "0")
    BOOT_SKIP=$(grep -c '"bootstrap_skip"' "$EVIDENCE_DIR/logs/bootstrap.log" 2>/dev/null || echo "0")
    ok "bootstrap events: schema_ensured=$SCHEMA_COUNT  bootstrap_done=$BOOT_DONE  bootstrap_skip=$BOOT_SKIP"
    echo "schema_ensured_count=$SCHEMA_COUNT" > "$EVIDENCE_DIR/logs/bootstrap-counters.txt"
    echo "bootstrap_done_count=$BOOT_DONE" >> "$EVIDENCE_DIR/logs/bootstrap-counters.txt"
    echo "bootstrap_skip_count=$BOOT_SKIP" >> "$EVIDENCE_DIR/logs/bootstrap-counters.txt"
else
    warn "log group $BOOT_LG not found"
fi

# Terraform state outputs (folded into this section)
(cd "$TF_DIR" && terraform output -json) > "$EVIDENCE_DIR/terraform-output.json"
ok "terraform-output.json: $(wc -c <"$EVIDENCE_DIR/terraform-output.json" | tr -d ' ') bytes"

# ─── 5. SLO dashboard panels (API path, SCP-resilient) ────────────────────
# AWS Console UI for CloudWatch Dashboards typically requires
# cloudwatch:ListMetrics, which is SCP-denied at the org level for many
# staging/dev accounts (positive guardrail signal). The dashboard provisioned
# by terraform/main.tf still exists and alarms still fire — but the Console
# screenshot path is unavailable. Fall back to the same API path the rest of
# this script uses: aws cloudwatch get-metric-widget-image (per-widget PNG
# render) + describe-alarms (alarm state JSON).
section "5/6 — SLO dashboard panels + alarm state (API path)"

mkdir -p "$EVIDENCE_DIR/slo"

# Widget JSON for each SLO panel — kept here (not extracted via get-dashboard)
# so this script works even if cloudwatch:GetDashboard is also SCP-restricted.
# Mirrors the widget array in terraform/main.tf aws_cloudwatch_dashboard.slo;
# any change there should be mirrored here.

slo_capture() {
    local fname="$1" widget="$2"
    local out="$EVIDENCE_DIR/slo/$fname"
    if aws cloudwatch get-metric-widget-image --region "$REGION" \
         --metric-widget "$widget" --output text --query 'MetricWidgetImage' 2>/dev/null \
         | base64 -d > "$out" 2>/dev/null; then
        if [[ -s "$out" ]]; then
            ok "SLO panel: $fname ($(wc -c <"$out" | tr -d ' ') bytes)"
        else
            rm -f "$out"
            warn "SLO panel: $fname empty — namespace 'aegis-enclave' has no datapoints yet (run cloud-smoke first to seed metrics)"
        fi
    else
        warn "SLO panel: $fname capture failed"
    fi
}

# Panel 1: API latency p50/p95/p99 with 500ms SLO threshold annotation
slo_capture "01-api-latency.png" '{
  "metrics":[
    ["aegis-enclave","request_latency_ms",{"stat":"p50","label":"p50"}],
    [".",".",{"stat":"p95","label":"p95"}],
    [".",".",{"stat":"p99","label":"p99"}]
  ],
  "period":60,"width":1024,"height":400,
  "title":"API request latency (SLO p99 < 500ms)",
  "annotations":{"horizontal":[{"value":500,"label":"SLO p99 target","color":"#d62728"}]}}'

# Panel 2: 5xx error rate % with multi-window burn thresholds
slo_capture "02-error-rate.png" '{
  "metrics":[
    [{"expression":"100 * (FILL(m_errors, 0) / m_total)","label":"5xx error rate %","id":"rate"}],
    ["aegis-enclave","request_errors_5xx",{"id":"m_errors","visible":false,"stat":"Sum"}],
    [".","request_total",{"id":"m_total","visible":false,"stat":"Sum"}]
  ],
  "period":60,"width":1024,"height":400,
  "title":"5xx error rate % (SLO target < 0.1%)",
  "annotations":{"horizontal":[
    {"value":0.1,"label":"SLO target","color":"#2ca02c"},
    {"value":0.6,"label":"Slow-burn threshold (6× SLO, 6h)","color":"#ff7f0e"},
    {"value":1.44,"label":"Fast-burn threshold (14.4× SLO, 1h)","color":"#d62728"}
  ]}}'

# Panel 3: Cache hit ratio %
slo_capture "03-cache-hit-ratio.png" '{
  "metrics":[
    [{"expression":"100 * (FILL(m_hit, 0) / (FILL(m_hit, 0) + FILL(m_miss, 0)))","label":"cache hit ratio %","id":"ratio"}],
    ["aegis-enclave","cache_hit_count",{"id":"m_hit","visible":false,"stat":"Sum"}],
    [".","cache_miss_count",{"id":"m_miss","visible":false,"stat":"Sum"}]
  ],
  "period":60,"width":1024,"height":400,
  "title":"Cache hit ratio % (SLO target ≥ 80%)",
  "yAxis":{"left":{"min":0,"max":100}},
  "annotations":{"horizontal":[{"value":80,"label":"SLO target","color":"#2ca02c"}]}}'

# Panel 4: Compute path latency p50/p95/p99 with SIGALRM ceiling
slo_capture "04-compute-duration.png" '{
  "metrics":[
    ["aegis-enclave","compute_duration_ms",{"stat":"p50","label":"p50"}],
    [".",".",{"stat":"p95","label":"p95"}],
    [".",".",{"stat":"p99","label":"p99"}]
  ],
  "period":60,"width":1024,"height":400,
  "title":"Worker compute duration (SIGALRM ceiling 60s)",
  "annotations":{"horizontal":[
    {"value":30000,"label":"SLO p95 target 30s","color":"#ff7f0e"},
    {"value":60000,"label":"SIGALRM hard ceiling","color":"#d62728"}
  ]}}'

# Panel 5: Request volume + cache breakdown (context for SLO interpretation)
slo_capture "05-volume-breakdown.png" '{
  "metrics":[
    ["aegis-enclave","request_total",{"stat":"Sum","label":"Total requests"}],
    [".","cache_hit_count",{"stat":"Sum","label":"Cache hits"}],
    [".","cache_miss_count",{"stat":"Sum","label":"Cache misses"}]
  ],
  "period":60,"width":1024,"height":400,
  "title":"Request volume + cache breakdown"}'

# Panel 6: Alarm state snapshot — JSON dump of current alarm states.
# get-metric-widget-image doesn't render alarm-type widgets, so this is a
# JSON evidence file rather than a PNG. Reviewer reads OK / ALARM / INSUFFICIENT_DATA
# state for every aegis-enclave-* alarm.
aws cloudwatch describe-alarms --region "$REGION" \
    --alarm-name-prefix "aegis-enclave" \
    --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Reason:StateReason,Updated:StateUpdatedTimestamp} | CompositeAlarms[*].{Name:AlarmName,State:StateValue,Reason:StateReason,Updated:StateUpdatedTimestamp}' \
    --output json > "$EVIDENCE_DIR/slo/06-alarm-state.json" 2>/dev/null \
    && ok "alarm state snapshot → slo/06-alarm-state.json" \
    || warn "alarm state snapshot failed"

# Panel 7: Alarm history (last hour) — proves alarms transition correctly,
# captures any deliberate test-alarm trigger fired during the evidence window
# (per cloud-up.sh post-message: set-alarm-state ALARM → email → set OK).
HISTORY_START=$(date -u -v-1H +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%S)
aws cloudwatch describe-alarm-history --region "$REGION" \
    --alarm-name "aegis-enclave-slo-fast-burn" \
    --history-item-type "StateUpdate" \
    --start-date "$HISTORY_START" \
    --query 'AlarmHistoryItems[*].{Time:Timestamp,Summary:HistorySummary}' \
    --output json > "$EVIDENCE_DIR/slo/07-alarm-history-fast-burn.json" 2>/dev/null \
    && ok "alarm history (slo_fast_burn last 1h) → slo/07-alarm-history-fast-burn.json" \
    || warn "alarm history fetch failed"

# ─── 6. Summary stub ─────────────────────────────────────────────────────
section "6/6 — summary.md stub"
cat > "$EVIDENCE_DIR/summary.md" <<EOF
# Phase 2.5 Evidence — $TS

## Operator
- Account: $ACCOUNT_ID
- Region:  $REGION
- Caller:  $ARN

## Captured (machine-readable)
- 6 CloudWatch metric widgets — AWS-native services (metrics/*.png) — chrome-sparse, API-fetched
- 5 SLO dashboard panels — application SLI (slo/0[1-5]-*.png) — API path; Console may be SCP-blocked
- 1 alarm state snapshot (slo/06-alarm-state.json) — current OK/ALARM state for every aegis-enclave-* alarm
- 1 alarm history excerpt (slo/07-alarm-history-fast-burn.json) — state transitions in last 1h, captures deliberate-trigger evidence
- Worker CloudWatch logs ($([[ -f "$EVIDENCE_DIR/logs/worker.log" ]] && echo "captured" || echo "MISSING — log group not present"))
- Bootstrap CloudWatch logs ($([[ -f "$EVIDENCE_DIR/logs/bootstrap.log" ]] && echo "captured" || echo "MISSING — log group not present"))
- Cache assertion counters: logs/worker-cache-counters.txt (cache_hit vs compute_done)
- Bootstrap idempotency counters: logs/bootstrap-counters.txt
- terraform-output.json (full state surface)

## Cache assertion (from worker log, last 10 min)
- cache_hit:    ${HIT_COUNT:-N/A}
- compute_done: ${COMPUTE_COUNT:-N/A}
- Interpretation: with the 7-step cloud-smoke, expect ≥1 cache_hit (step 3 +
  step 5) and ≥2 compute_done (step 1 cache-miss + step 4 partial-overlap).
  All-zero cache_hit → bootstrap pre-warm did not complete OR find_covering
  did not match — read bootstrap.log + worker.log for diagnosis.

## Bootstrap idempotency (from bootstrap log)
- schema_ensured:  ${SCHEMA_COUNT:-N/A}  (each apply triggers schema check)
- bootstrap_done:  ${BOOT_DONE:-N/A}     (cache seed written)
- bootstrap_skip:  ${BOOT_SKIP:-N/A}     (cache already seeded — re-run no-op)

## To add manually (browser-side / reviewer-grade)
- [ ] Full CloudWatch dashboard screenshot (with chrome / titles / time range visible)
- [ ] cloud-smoke 7/7 terminal output (paste into smoke.txt or screenshot)
- [ ] AWS Client VPN handshake confirmation (Tunnelblick log or 'tunnelblick status')
- [ ] AWS Console VPC topology screenshot (showing aegis-enclave-* tagged resources)

## Phase 2.5 cost-window markers
- Apply started:    (fill in from cloud-up.sh start time)
- Smoke completed:  (fill in)
- Evidence captured (this script ran): $TS
- Destroy started:  (fill in from cloud-down.sh start time — must be < 3h after apply)
EOF
ok "summary.md written"

# ─── Done ────────────────────────────────────────────────────────────────
section "Evidence capture complete"
echo
echo "  Output:    $EVIDENCE_DIR"
echo "  Files:     $(find "$EVIDENCE_DIR" -type f | wc -l | tr -d ' ')"
echo "  Total:     $(du -sh "$EVIDENCE_DIR" | cut -f1)"
echo
info "Reminder per memory feedback_phase25_screenshot_evidence.md:"
info "supplement metrics/*.png with browser-side full-dashboard screenshots"
info "BEFORE running 'make cloud-down' (terraform destroy is irreversible)."
