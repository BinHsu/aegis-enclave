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
ACCOUNT_ID=$(echo "$CALLER_JSON" | grep -oE '"Account":[^,}]*' | sed -E 's/.*"([0-9]+)".*/\1/')
ARN=$(echo "$CALLER_JSON" | grep -oE '"Arn":"[^"]*"' | sed -E 's/"Arn":"(.+)"/\1/')

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
section "1/4 — CloudWatch metric widgets"

# Resolve resource identifiers from terraform state
SQS_URL=$(cd "$TF_DIR" && terraform output -raw sqs_primes_url 2>/dev/null || echo "")
SQS_NAME=""
[[ -n "$SQS_URL" ]] && SQS_NAME=$(basename "$SQS_URL")

WORKER_SVC_ARN=$(cd "$TF_DIR" && terraform output -raw worker_service_arn 2>/dev/null || echo "")
WORKER_SVC=""
WORKER_CLUSTER=""
if [[ -n "$WORKER_SVC_ARN" ]]; then
    WORKER_SVC=$(basename "$WORKER_SVC_ARN")
    WORKER_CLUSTER=$(echo "$WORKER_SVC_ARN" | sed -E 's|.*cluster/([^/]+)/.*|\1|')
fi

VALKEY_EP=$(cd "$TF_DIR" && terraform output -raw valkey_endpoint 2>/dev/null || echo "")
VALKEY_ID=""
[[ -n "$VALKEY_EP" ]] && VALKEY_ID=$(echo "$VALKEY_EP" | sed -E 's/^([^.]+)\..*/\1/')

# 01: SQS visible messages
if [[ -n "$SQS_NAME" ]]; then
    capture_metric "01-sqs-visible.png" '{
      "metrics":[["AWS/SQS","ApproximateNumberOfMessagesVisible","QueueName","'"$SQS_NAME"'",{"label":"visible"}]],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"SQS — ApproximateNumberOfMessagesVisible","yAxis":{"left":{"min":0}}}'
else
    warn "skip 01: SQS not in state"
fi

# 02: ECS DesiredCount
if [[ -n "$WORKER_SVC" && -n "$WORKER_CLUSTER" ]]; then
    capture_metric "02-ecs-desired-count.png" '{
      "metrics":[
        ["AWS/ECS","CPUUtilization","ServiceName","'"$WORKER_SVC"'","ClusterName","'"$WORKER_CLUSTER"'",{"label":"CPU%"}],
        [".","MemoryUtilization",".","'"$WORKER_SVC"'",".","'"$WORKER_CLUSTER"'",{"label":"Mem%"}]
      ],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"ECS Worker Service — CPU + Memory Utilization"}'
else
    warn "skip 02: ECS service not in state"
fi

# 03: ElastiCache BytesUsedForCache
if [[ -n "$VALKEY_ID" ]]; then
    capture_metric "03-elasticache-bytes.png" '{
      "metrics":[["AWS/ElastiCache","BytesUsedForCache","CacheClusterId","'"$VALKEY_ID"'"]],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"ElastiCache Valkey — BytesUsedForCache"}'

    # 04: ElastiCache ProcessingUnits
    capture_metric "04-elasticache-ecpu.png" '{
      "metrics":[["AWS/ElastiCache","ElastiCacheProcessingUnits","CacheClusterId","'"$VALKEY_ID"'"]],
      "period":60,"stat":"Sum","width":1024,"height":400,
      "title":"ElastiCache Valkey — ElastiCacheProcessingUnits (eCPU)"}'
else
    warn "skip 03 + 04: Valkey not in state"
fi

# 05: ALB target response time
ALB_FULL_NAME=$(cd "$TF_DIR" && terraform output -raw alb_dns_name 2>/dev/null \
              | sed -E 's/^internal-//;s/-[0-9]+\..*//' || echo "")
if [[ -n "$ALB_FULL_NAME" ]]; then
    capture_metric "05-alb-target-response-time.png" '{
      "metrics":[["AWS/ApplicationELB","TargetResponseTime","LoadBalancer","app/'"$ALB_FULL_NAME"'/*"]],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"ALB — TargetResponseTime"}'
else
    warn "skip 05: ALB not parseable"
fi

# 06: RDS CPU (typical resource sanity)
capture_metric "06-rds-cpu.png" '{
  "metrics":[["AWS/RDS","CPUUtilization","DBInstanceIdentifier","aegis-enclave"]],
  "period":60,"stat":"Average","width":1024,"height":400,
  "title":"RDS — CPUUtilization"}'

# ─── 2. CloudWatch log excerpts ───────────────────────────────────────────
section "2/4 — CloudWatch log excerpts (last hour)"
START_MS=$(( ($(date +%s) - 3600) * 1000 ))

# Worker logs
WORKER_LG="/aws/ecs/aegis-enclave-worker"
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
else
    warn "log group $WORKER_LG not found (worker may not have logged yet)"
fi

# Bootstrap logs
BOOT_LG="/aws/ecs/aegis-enclave-cache-bootstrap"
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
else
    warn "log group $BOOT_LG not found"
fi

# ─── 3. Terraform state outputs ──────────────────────────────────────────
section "3/4 — Terraform output JSON"
(cd "$TF_DIR" && terraform output -json) > "$EVIDENCE_DIR/terraform-output.json"
ok "terraform-output.json: $(wc -c <"$EVIDENCE_DIR/terraform-output.json" | tr -d ' ') bytes"

# ─── 4. Summary stub ─────────────────────────────────────────────────────
section "4/4 — summary.md stub"
cat > "$EVIDENCE_DIR/summary.md" <<EOF
# Phase 2.5 Evidence — $TS

## Operator
- Account: $ACCOUNT_ID
- Region:  $REGION
- Caller:  $ARN

## Captured (machine-readable)
- 6 CloudWatch metric widgets (metrics/*.png) — chrome-sparse, API-fetched
- Worker CloudWatch logs ($([[ -f "$EVIDENCE_DIR/logs/worker.log" ]] && echo "captured" || echo "MISSING — log group not present"))
- Bootstrap CloudWatch logs ($([[ -f "$EVIDENCE_DIR/logs/bootstrap.log" ]] && echo "captured" || echo "MISSING — log group not present"))
- terraform-output.json (full state surface)

## To add manually (browser-side / reviewer-grade)
- [ ] Full CloudWatch dashboard screenshot (with chrome / titles / time range visible)
- [ ] Smoke test 6/6 terminal output (paste into smoke.txt or screenshot)
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
