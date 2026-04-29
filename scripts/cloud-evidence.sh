#!/usr/bin/env bash
# cloud-evidence.sh — capture cloud-acceptance evidence artifacts before teardown.
#
# Per memory feedback_phase25_screenshot_evidence.md: 'terraform destroy' is
# irreversible — every dashboard / log line / handshake must be captured BEFORE
# 'make cloud-down'. This script automates the API-fetchable subset:
#
#   - 6 CloudWatch metric widget PNGs (SQS / ECS / ElastiCache / ALB / DynamoDB)
#   - Worker CloudWatch log excerpts (last hour)
#   - Bootstrap task CloudWatch log excerpts (idempotency proof)
#   - terraform output (state-as-evidence)
#   - summary.md stub for browser-side screenshots + manual notes
#
# Output layout (region-suffixed for forker portability):
#   evidence/<UTC-timestamp>/
#     metrics-<primary-region>/01-sqs-visible.png
#     metrics-<primary-region>/02-ecs-worker-utilization.png
#     metrics-<primary-region>/03-elasticache-bytes.png
#     metrics-<primary-region>/04-elasticache-ecpu.png
#     metrics-<primary-region>/05-alb-target-response-time.png
#     metrics-<primary-region>/06-ddb-throttles.png
#     metrics-<secondary-region>/01-sqs-visible.png       (multi-region only)
#     metrics-<secondary-region>/06-ddb-throttles.png     (multi-region only)
#     logs/worker-<primary-region>.log
#     logs/worker-<secondary-region>.log                  (multi-region only)
#     logs/bootstrap-<primary-region>.log
#     logs/worker-cache-counters-<region>.txt             (one per region)
#     logs/bootstrap-counters.txt
#     ddb-<primary-region>.json                           (Global Tables Replicas[] proof)
#     ddb-<secondary-region>.json                         (multi-region only)
#     r53-hc-<key>-<id>-status.json                       (multi-region + route53_zone_name)
#     vpn-utun.txt                                        (always; empty body = no tunnel)
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
TFVARS="$TF_DIR/terraform.tfvars"

TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR="$REPO_ROOT/evidence/$TS"
mkdir -p "$EVIDENCE_DIR/logs"

section "aegis-enclave — cloud-acceptance evidence capture"
echo "Output: $EVIDENCE_DIR"

# ─── Pre-flight ──────────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1       || fail "aws CLI not found"
command -v terraform >/dev/null 2>&1 || fail "terraform not found"
command -v jq >/dev/null 2>&1        || fail "jq not found"
command -v base64 >/dev/null 2>&1    || fail "base64 not found"

# Resolve AWS_PROFILE: env var > tfvars persisted > interactive prompt.
# Per memory feedback_explicit_over_implicit.md: read explicitly, log source.
# Subshell with `|| true` per feedback_pipefail_optional_input_must_or_true.md.
if [[ -z "${AWS_PROFILE:-}" ]] && [[ -f "$TFVARS" ]]; then
    AWS_PROFILE_FROM_TFVARS=$( (grep -E '^aws_profile[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
    if [[ -n "$AWS_PROFILE_FROM_TFVARS" ]]; then
        export AWS_PROFILE="$AWS_PROFILE_FROM_TFVARS"
        info "Using AWS_PROFILE=$AWS_PROFILE (from $TFVARS)"
    fi
fi
if [[ -z "${AWS_PROFILE:-}" ]] && [[ -t 0 ]]; then
    PROFILES_AVAIL=$(aws configure list-profiles 2>/dev/null || true)
    if [[ -n "$PROFILES_AVAIL" ]]; then
        printf "Available AWS profiles:\n"
        echo "$PROFILES_AVAIL" | sed 's/^/  - /'
    fi
    printf "Enter AWS_PROFILE [default]: "
    read -r AWS_PROFILE_INPUT
    export AWS_PROFILE="${AWS_PROFILE_INPUT:-default}"
fi

CALLER_JSON=$(aws sts get-caller-identity 2>&1) \
    || fail "AWS auth failed (check AWS_PROFILE / aws sso login)"
# Use jq for robust JSON parsing (we already require jq above) instead of grep+sed
# regexes that break on whitespace variants in the JSON output.
ACCOUNT_ID=$(echo "$CALLER_JSON" | jq -r '.Account // "?"' 2>/dev/null || echo "?")
ARN=$(echo "$CALLER_JSON" | jq -r '.Arn // "?"' 2>/dev/null || echo "?")

REGION=$(grep -E '^region[[:space:]]*=' "$TF_DIR/terraform.tfvars" 2>/dev/null \
         | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
REGION="${REGION:-eu-central-1}"

# Multi-region: secondary_region empty = single-region scope; non-empty drives
# the per-region branches below (DDB describe, secondary worker log, secondary
# metric panels, Route53 health checks).
SECONDARY_REGION=$( (grep -E '^secondary_region[[:space:]]*=' "$TF_DIR/terraform.tfvars" 2>/dev/null || true) \
                   | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')

(cd "$TF_DIR" && terraform state list 2>/dev/null | head -1 >/dev/null) \
    || fail "no terraform state — run cloud-up first (exit 2)"

ok "AWS account: $ACCOUNT_ID  /  primary region: $REGION"
if [[ -n "$SECONDARY_REGION" ]]; then
    ok "secondary region: $SECONDARY_REGION (multi-region capture mode)"
else
    info "secondary_region empty — single-region capture"
fi

# Always create metrics dir for the primary region (region-suffixed scheme).
mkdir -p "$EVIDENCE_DIR/metrics-${REGION}"
[[ -n "$SECONDARY_REGION" ]] && mkdir -p "$EVIDENCE_DIR/metrics-${SECONDARY_REGION}"

# Helper: capture a metric widget PNG.
# Args: $1 = region, $2 = filename, $3 = widget JSON.
# Output: $EVIDENCE_DIR/metrics-<region>/<filename>.
capture_metric() {
    local region="$1" fname="$2" widget="$3"
    local out="$EVIDENCE_DIR/metrics-${region}/$fname"
    if aws cloudwatch get-metric-widget-image --region "$region" \
         --metric-widget "$widget" --output text --query 'MetricWidgetImage' 2>/dev/null \
         | base64 -d > "$out" 2>/dev/null; then
        if [[ -s "$out" ]]; then
            ok "metric ($region): $fname ($(wc -c <"$out" | tr -d ' ') bytes)"
        else
            rm -f "$out"
            warn "metric ($region): $fname empty — resource may not exist yet"
        fi
    else
        warn "metric ($region): $fname capture failed — resource may not exist yet"
    fi
}

# ─── 1. CloudWatch metric widgets ─────────────────────────────────────────
section "1/6 — CloudWatch metric widgets (AWS-native services)"

# Resolve resource identifiers DIRECTLY from terraform outputs (added in
# outputs.tf). Each output is the bare identifier CloudWatch expects in the
# corresponding metric dimension. Reading from outputs (rather than
# reverse-engineering from ARNs / DNS strings) avoids the parsing bugs that
# previously made 5/6 widgets empty:
#   - DynamoDB uses TableName from terraform output (not hardcoded)
#   - ElastiCache Serverless uses CacheName, NOT CacheClusterId
#   - ALB needs "app/<name>/<id>" suffix, not the DNS-stripped name
SQS_NAME=$(cd "$TF_DIR" && terraform output -raw sqs_primes_name 2>/dev/null || echo "")
WORKER_SVC=$(cd "$TF_DIR" && terraform output -raw worker_service_name 2>/dev/null || echo "")
WORKER_CLUSTER=$(cd "$TF_DIR" && terraform output -raw ecs_cluster_name 2>/dev/null || echo "")
VALKEY_NAME=$(cd "$TF_DIR" && terraform output -raw valkey_cache_name 2>/dev/null || echo "")
ALB_ARN_SUFFIX=$(cd "$TF_DIR" && terraform output -raw alb_arn_suffix 2>/dev/null || echo "")
TG_ARN_SUFFIX=$(cd "$TF_DIR" && terraform output -raw alb_target_group_arn_suffix 2>/dev/null || echo "")
DDB_TABLE_NAME=$(cd "$TF_DIR" && terraform output -raw dynamodb_table_name 2>/dev/null || echo "")

info "Resolved dimensions:"
info "  SQS QueueName:                 ${SQS_NAME:-MISSING}"
info "  ECS ClusterName:               ${WORKER_CLUSTER:-MISSING}"
info "  ECS ServiceName (worker):      ${WORKER_SVC:-MISSING}"
info "  ElastiCache CacheName:         ${VALKEY_NAME:-MISSING}"
info "  ALB LoadBalancer arn_suffix:   ${ALB_ARN_SUFFIX:-MISSING}"
info "  ALB TargetGroup arn_suffix:    ${TG_ARN_SUFFIX:-MISSING}"
info "  DynamoDB TableName:            ${DDB_TABLE_NAME:-MISSING}"

# Pre-flight discovery: list metrics that ACTUALLY exist for each namespace.
# Helps debug empty widgets — if list-metrics returns nothing for a namespace,
# the resource hasn't emitted metrics yet (insufficient time / no traffic),
# distinct from a wrong-dimension bug.
section "2/6 — Discovery dry-run (list-metrics per namespace)"
for ns in AWS/SQS AWS/ECS AWS/ElastiCache AWS/ApplicationELB AWS/DynamoDB; do
    count=$(aws cloudwatch list-metrics --region "$REGION" --namespace "$ns" \
              --query 'Metrics | length(@)' --output text 2>/dev/null || echo "?")
    if [[ "$count" == "0" ]] || [[ "$count" == "?" ]]; then
        warn "$ns: $count metrics published yet (resource may need warm-up traffic)"
    else
        ok "$ns: $count metrics published"
    fi
done

# 01: SQS visible messages
section "3/6 — Capture metric widgets (primary region: $REGION)"
if [[ -n "$SQS_NAME" ]]; then
    capture_metric "$REGION" "01-sqs-visible.png" '{
      "metrics":[["AWS/SQS","ApproximateNumberOfMessagesVisible","QueueName","'"$SQS_NAME"'",{"label":"visible"}]],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"SQS '"$SQS_NAME"' — ApproximateNumberOfMessagesVisible","yAxis":{"left":{"min":0}}}'
else
    warn "skip 01: sqs_primes_name output missing"
fi

# 02: ECS Worker CPU + Memory utilization
if [[ -n "$WORKER_SVC" && -n "$WORKER_CLUSTER" ]]; then
    capture_metric "$REGION" "02-ecs-worker-utilization.png" '{
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
    capture_metric "$REGION" "03-elasticache-bytes.png" '{
      "metrics":[["AWS/ElastiCache","BytesUsedForCache","CacheName","'"$VALKEY_NAME"'"]],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"ElastiCache Serverless '"$VALKEY_NAME"' — BytesUsedForCache"}'

    # 04: ElastiCache ProcessingUnits (Serverless-specific metric, CacheName dim)
    capture_metric "$REGION" "04-elasticache-ecpu.png" '{
      "metrics":[["AWS/ElastiCache","ElastiCacheProcessingUnits","CacheName","'"$VALKEY_NAME"'"]],
      "period":60,"stat":"Sum","width":1024,"height":400,
      "title":"ElastiCache Serverless '"$VALKEY_NAME"' — ProcessingUnits (eCPU)"}'
else
    warn "skip 03 + 04: valkey_cache_name output missing"
fi

# 05: ALB TargetResponseTime — needs both LoadBalancer + TargetGroup arn suffixes
if [[ -n "$ALB_ARN_SUFFIX" && -n "$TG_ARN_SUFFIX" ]]; then
    capture_metric "$REGION" "05-alb-target-response-time.png" '{
      "metrics":[
        ["AWS/ApplicationELB","TargetResponseTime","LoadBalancer","'"$ALB_ARN_SUFFIX"'","TargetGroup","'"$TG_ARN_SUFFIX"'",{"label":"target ms"}],
        [".","RequestCount",".",".",".",".",{"label":"requests","stat":"Sum","yAxis":"right"}]
      ],
      "period":60,"stat":"Average","width":1024,"height":400,
      "title":"ALB — TargetResponseTime + RequestCount"}'
else
    warn "skip 05: alb_arn_suffix / alb_target_group_arn_suffix output missing"
fi

# 06: DynamoDB consumed RCU/WCU + ThrottledRequests (uses TableName from output)
# RCU/WCU are Sum-stat metrics — total capacity units consumed in the period.
# ThrottledRequests on yAxis=right because it's a count (not capacity), and a
# spike there is the headline signal for an under-provisioned PAY_PER_REQUEST
# table or a partition-key hot-spot.
if [[ -n "$DDB_TABLE_NAME" ]]; then
    capture_metric "$REGION" "06-ddb-throttles.png" '{
      "metrics":[
        ["AWS/DynamoDB","ConsumedReadCapacityUnits","TableName","'"$DDB_TABLE_NAME"'",{"label":"RCU","stat":"Sum"}],
        [".","ConsumedWriteCapacityUnits",".","'"$DDB_TABLE_NAME"'",{"label":"WCU","stat":"Sum"}],
        [".","ThrottledRequests",".","'"$DDB_TABLE_NAME"'",{"label":"throttles","yAxis":"right","stat":"Sum"}]
      ],
      "period":60,"stat":"Sum","width":1024,"height":400,
      "title":"DynamoDB '"$DDB_TABLE_NAME"' — RCU/WCU + Throttles"}'
else
    warn "skip 06: dynamodb_table_name output missing"
fi

# ─── Secondary region metric panels (multi-region only) ────────────────────
# Best-effort capture: only panels for which terraform exposes the bare
# CloudWatch dimension identifier in secondary outputs are captured. SQS
# bare-name is derivable from the URL (last path segment); ECS cluster name
# has a dedicated secondary output. ECS service / Valkey CacheName / ALB
# arn_suffix / TG arn_suffix are not exported per-region in outputs.tf, so
# panels 02 / 03 / 04 / 05 are skipped on secondary. Panel 06 (DynamoDB) uses
# the same TableName (Global Tables share the table identity); the per-region
# metrics are captured against each region endpoint.
if [[ -n "$SECONDARY_REGION" ]]; then
    section "3b/6 — Capture metric widgets (secondary region: $SECONDARY_REGION)"

    SECONDARY_SQS_URL=$(cd "$TF_DIR" && terraform output -raw secondary_sqs_primes_url 2>/dev/null || echo "")
    SECONDARY_SQS_NAME=""
    if [[ -n "$SECONDARY_SQS_URL" ]] && [[ "$SECONDARY_SQS_URL" != "null" ]]; then
        SECONDARY_SQS_NAME=$(echo "$SECONDARY_SQS_URL" | sed -E 's|.*/([^/]+)$|\1|')
    fi
    SECONDARY_ECS_CLUSTER=$(cd "$TF_DIR" && terraform output -raw secondary_ecs_cluster_name 2>/dev/null || echo "")
    [[ "$SECONDARY_ECS_CLUSTER" == "null" ]] && SECONDARY_ECS_CLUSTER=""

    info "Secondary dimensions:"
    info "  SQS QueueName:                 ${SECONDARY_SQS_NAME:-MISSING}"
    info "  ECS ClusterName:               ${SECONDARY_ECS_CLUSTER:-MISSING}"
    info "  DynamoDB TableName:            ${DDB_TABLE_NAME:-MISSING} (Global Tables — same TableName both regions)"
    info "  (ECS service / Valkey CacheName / ALB arn_suffix not exported per-region — panels 02/03/04/05 skipped)"

    if [[ -n "$SECONDARY_SQS_NAME" ]]; then
        capture_metric "$SECONDARY_REGION" "01-sqs-visible.png" '{
          "metrics":[["AWS/SQS","ApproximateNumberOfMessagesVisible","QueueName","'"$SECONDARY_SQS_NAME"'",{"label":"visible"}]],
          "period":60,"stat":"Average","width":1024,"height":400,
          "title":"SQS '"$SECONDARY_SQS_NAME"' ('"$SECONDARY_REGION"') — ApproximateNumberOfMessagesVisible","yAxis":{"left":{"min":0}}}'
    else
        warn "skip secondary 01: secondary_sqs_primes_url output missing"
    fi

    if [[ -n "$DDB_TABLE_NAME" ]]; then
        capture_metric "$SECONDARY_REGION" "06-ddb-throttles.png" '{
          "metrics":[
            ["AWS/DynamoDB","ConsumedReadCapacityUnits","TableName","'"$DDB_TABLE_NAME"'",{"label":"RCU","stat":"Sum"}],
            [".","ConsumedWriteCapacityUnits",".","'"$DDB_TABLE_NAME"'",{"label":"WCU","stat":"Sum"}],
            [".","ThrottledRequests",".","'"$DDB_TABLE_NAME"'",{"label":"throttles","yAxis":"right","stat":"Sum"}]
          ],
          "period":60,"stat":"Sum","width":1024,"height":400,
          "title":"DynamoDB '"$DDB_TABLE_NAME"' ('"$SECONDARY_REGION"' replica) — RCU/WCU + Throttles"}'
    fi
fi

# ─── 4. CloudWatch log excerpts + cache-hit ground-truth counters ─────────
section "4/6 — CloudWatch log excerpts + cache_hit/compute_done ground truth"
START_MS=$(( ($(date +%s) - 3600) * 1000 ))
SHORT_START_MS=$(( ($(date +%s) - 600) * 1000 ))  # last 10 min — used for cache counter window
# Bootstrap is one-shot at cloud-up T0. Cloud-acceptance windows can run up to
# 3h (per cost discipline), and evidence capture can lag further. 12h covers
# any reasonable cycle. Bootstrap log is tiny (1-2 events) — wider window is
# free.
BOOT_START_MS=$(( ($(date +%s) - 43200) * 1000 ))

# Helper: capture worker log + cache counters from one region.
# Sets globals HIT_COUNT / COMPUTE_COUNT (primary region only — used in summary).
fetch_worker_log() {
    local region="$1" out_file="$2" is_primary="$3"
    local lg="/ecs/aegis-enclave-worker"
    if ! aws logs describe-log-groups --region "$region" --log-group-name-prefix "$lg" \
           --query 'logGroups[0].logGroupName' --output text 2>/dev/null \
           | grep -q "$lg"; then
        warn "log group $lg not found in $region (worker may not have logged yet)"
        return 0
    fi
    aws logs filter-log-events --region "$region" \
        --log-group-name "$lg" \
        --start-time "$START_MS" \
        --output text \
        --query 'events[*].[timestamp,message]' \
        > "$out_file" 2>/dev/null \
        && ok "worker logs ($region): $(wc -l <"$out_file" | tr -d ' ') lines → $(basename "$out_file")" \
        || warn "worker log fetch failed in $region"

    local hits computes
    hits=$(aws logs filter-log-events --region "$region" \
             --log-group-name "$lg" \
             --start-time "$SHORT_START_MS" \
             --filter-pattern '"cache_hit"' \
             --query 'events | length(@)' --output text 2>/dev/null || echo "?")
    computes=$(aws logs filter-log-events --region "$region" \
                 --log-group-name "$lg" \
                 --start-time "$SHORT_START_MS" \
                 --filter-pattern '"compute_done"' \
                 --query 'events | length(@)' --output text 2>/dev/null || echo "?")
    ok "worker cache events ($region, last 10min): cache_hit=$hits  compute_done=$computes"
    {
        echo "region=$region"
        echo "cache_hit_count=$hits"
        echo "compute_done_count=$computes"
    } > "$EVIDENCE_DIR/logs/worker-cache-counters-${region}.txt"

    if [[ "$is_primary" == "1" ]]; then
        HIT_COUNT="$hits"
        COMPUTE_COUNT="$computes"
        if [[ "$hits" == "0" ]]; then
            warn "0 cache_hit events in primary — either bootstrap didn't seed, find_covering didn't match,"
            warn "or smoke wasn't run within the last 10 min. Check bootstrap-${region}.log + worker-${region}.log."
        fi
    fi
}

# Worker logs — full excerpt for forensic browsing (per region).
fetch_worker_log "$REGION" "$EVIDENCE_DIR/logs/worker-${REGION}.log" "1"
if [[ -n "$SECONDARY_REGION" ]]; then
    fetch_worker_log "$SECONDARY_REGION" "$EVIDENCE_DIR/logs/worker-${SECONDARY_REGION}.log" "0"
fi

# Bootstrap logs — proves schema migration + cache pre-warm completed (primary
# only; ADR-0042 architecture has bootstrap task in primary region — DDB
# Global Tables auto-replicates, no secondary-region bootstrap required).
BOOT_LG="/ecs/aegis-enclave-bootstrap"
BOOTSTRAP_LOG="$EVIDENCE_DIR/logs/bootstrap-${REGION}.log"
if aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$BOOT_LG" \
     --query 'logGroups[0].logGroupName' --output text 2>/dev/null \
     | grep -q "$BOOT_LG"; then
    aws logs filter-log-events --region "$REGION" \
        --log-group-name "$BOOT_LG" \
        --start-time "$BOOT_START_MS" \
        --output text \
        --query 'events[*].message' \
        2>/dev/null | tr '\t' '\n' > "$BOOTSTRAP_LOG" \
        && ok "bootstrap logs ($REGION): $(wc -l <"$BOOTSTRAP_LOG" | tr -d ' ') lines → $(basename "$BOOTSTRAP_LOG")" \
        || warn "bootstrap log fetch failed"

    # Bootstrap idempotency proof — count schema_ensured + bootstrap_done/skip
    SCHEMA_COUNT=$(grep -c '"schema_ensured"' "$BOOTSTRAP_LOG" 2>/dev/null || echo "0")
    BOOT_DONE=$(grep -c '"bootstrap_done"' "$BOOTSTRAP_LOG" 2>/dev/null || echo "0")
    BOOT_SKIP=$(grep -c '"bootstrap_skip"' "$BOOTSTRAP_LOG" 2>/dev/null || echo "0")
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

# ─── 4b. DDB describe-table per region (Global Tables Replicas[] proof) ────
# Multi-region active-active proof: each region's DDB endpoint reports the
# Replicas[] array with the OTHER region(s). cloud-evidence-verify.sh asserts
# Replicas[] non-empty as the configured-correctly check.
# Full region string in filename (ddb-<region>.json) for forker portability —
# avoids hardcoded region nicknames (fra/ire) that don't transfer to
# us-west-2 / ap-southeast-1 / etc.
section "4b/6 — DDB describe-table per region (Global Tables Replicas[] proof)"
if [[ -n "$DDB_TABLE_NAME" ]]; then
    aws dynamodb describe-table --region "$REGION" \
        --table-name "$DDB_TABLE_NAME" \
        > "$EVIDENCE_DIR/ddb-${REGION}.json" 2>/dev/null \
        && ok "ddb-${REGION}.json: $(wc -c <"$EVIDENCE_DIR/ddb-${REGION}.json" | tr -d ' ') bytes" \
        || warn "ddb describe-table ($REGION) failed"

    if [[ -n "$SECONDARY_REGION" ]]; then
        aws dynamodb describe-table --region "$SECONDARY_REGION" \
            --table-name "$DDB_TABLE_NAME" \
            > "$EVIDENCE_DIR/ddb-${SECONDARY_REGION}.json" 2>/dev/null \
            && ok "ddb-${SECONDARY_REGION}.json: $(wc -c <"$EVIDENCE_DIR/ddb-${SECONDARY_REGION}.json" | tr -d ' ') bytes" \
            || warn "ddb describe-table ($SECONDARY_REGION) failed — Global Tables replica may not be ACTIVE yet"
    fi
else
    warn "skip DDB describe: dynamodb_table_name output missing"
fi

# ─── 4c. Route53 health-check status (multi-region only, opt-in zone) ──────
# health-check IDs come from terraform output route53_health_check_ids (a map
# {primary: <id>, secondary: <id>}). When secondary_region is empty OR
# route53_zone_name was empty in tfvars, the map is {} — gracefully skip.
section "4c/6 — Route53 health-check status (multi-region only)"
HC_JSON=$(cd "$TF_DIR" && terraform output -json route53_health_check_ids 2>/dev/null || echo "{}")
if [[ "$HC_JSON" != "{}" ]] && [[ -n "$HC_JSON" ]]; then
    # Iterate each (key, id) pair. Route53 health-check API is global (us-east-1)
    # — pass --region us-east-1 explicitly so the call works regardless of
    # operator's default-region config.
    echo "$HC_JSON" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r key hc_id; do
        [[ -z "$hc_id" ]] && continue
        out="$EVIDENCE_DIR/r53-hc-${key}-${hc_id}-status.json"
        if aws route53 get-health-check-status --region us-east-1 \
             --health-check-id "$hc_id" > "$out" 2>/dev/null; then
            ok "r53 health-check ($key=$hc_id) → $(basename "$out")"
        else
            warn "r53 get-health-check-status failed for $key=$hc_id"
            rm -f "$out"
        fi
    done
else
    info "no Route53 health checks (multi-region disabled or route53_zone_name empty in tfvars) — skip gracefully"
fi

# ─── 4d. VPN handshake / utun capture (always — empty file documents "no VPN") ─
# Captured-but-empty file is itself evidence ("no active VPN at evidence-capture
# time"). macOS path: ifconfig | grep utun. Linux fallback: wg show.
section "4d/6 — VPN handshake (utun / wg show)"
VPN_OUT="$EVIDENCE_DIR/vpn-utun.txt"
{
    echo "# vpn-utun.txt — captured $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Empty body below = no active VPN tunnel at evidence-capture time"
    echo "# (still valid evidence: documents the operator's connectivity state)"
    echo "---"
    if command -v ifconfig >/dev/null 2>&1; then
        echo "## ifconfig | grep -A2 utun (macOS)"
        ifconfig 2>/dev/null | grep -A2 -E '^utun[0-9]+:' || echo "(no utun interface)"
    fi
    if command -v wg >/dev/null 2>&1; then
        echo
        echo "## wg show (Linux WireGuard)"
        wg show 2>/dev/null || echo "(wg show — none / requires sudo)"
    fi
} > "$VPN_OUT"
ok "vpn-utun.txt: $(wc -c <"$VPN_OUT" | tr -d ' ') bytes (empty body = no active tunnel)"

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
# Cloud-Acceptance Evidence — $TS

## Operator
- Account:   $ACCOUNT_ID
- Primary:   $REGION
- Secondary: ${SECONDARY_REGION:-(single-region scope)}
- Caller:    $ARN

## Captured (machine-readable)
- CloudWatch AWS-native metric panels (primary): metrics-${REGION}/0[1-6]-*.png — chrome-sparse, API-fetched
$(if [[ -n "$SECONDARY_REGION" ]]; then echo "- CloudWatch AWS-native metric panels (secondary, best-effort): metrics-${SECONDARY_REGION}/*.png — only SQS + DDB exposed via terraform outputs in this iteration"; fi)
- 5 SLO dashboard panels — application SLI (slo/0[1-5]-*.png) — API path; Console may be SCP-blocked
- 1 alarm state snapshot (slo/06-alarm-state.json) — current OK/ALARM state for every aegis-enclave-* alarm
- 1 alarm history excerpt (slo/07-alarm-history-fast-burn.json) — state transitions in last 1h, captures deliberate-trigger evidence
- Worker CloudWatch logs (primary): $([[ -f "$EVIDENCE_DIR/logs/worker-${REGION}.log" ]] && echo "captured" || echo "MISSING")
$(if [[ -n "$SECONDARY_REGION" ]]; then echo "- Worker CloudWatch logs (secondary): $([[ -f "$EVIDENCE_DIR/logs/worker-${SECONDARY_REGION}.log" ]] && echo "captured" || echo "MISSING")"; fi)
- Bootstrap CloudWatch logs (primary): $([[ -f "$EVIDENCE_DIR/logs/bootstrap-${REGION}.log" ]] && echo "captured" || echo "MISSING")
- Cache assertion counters: logs/worker-cache-counters-<region>.txt (cache_hit vs compute_done, per region)
- Bootstrap idempotency counters: logs/bootstrap-counters.txt
- DDB describe-table (Global Tables Replicas[] proof): ddb-${REGION}.json$(if [[ -n "$SECONDARY_REGION" ]]; then echo " + ddb-${SECONDARY_REGION}.json"; fi)
- Route53 health-check status: r53-hc-*-status.json (one per HC ID; absent if multi-region disabled or route53_zone_name empty)
- VPN tunnel state: vpn-utun.txt (always written; empty body documents "no active tunnel at evidence time")
- terraform-output.json (full state surface)

## Cache assertion (from worker log, last 10 min, primary region)
- cache_hit:    ${HIT_COUNT:-N/A}
- compute_done: ${COMPUTE_COUNT:-N/A}
- Interpretation: with the 7-step cloud-smoke, expect ≥1 cache_hit (step 3 +
  step 5) and ≥2 compute_done (step 1 cache-miss + step 4 partial-overlap).
  All-zero cache_hit → bootstrap pre-warm did not complete OR find_covering
  did not match — read bootstrap-${REGION}.log + worker-${REGION}.log for diagnosis.

## Bootstrap idempotency (from bootstrap log)
- schema_ensured:  ${SCHEMA_COUNT:-N/A}  (each apply triggers schema check)
- bootstrap_done:  ${BOOT_DONE:-N/A}     (cache seed written)
- bootstrap_skip:  ${BOOT_SKIP:-N/A}     (cache already seeded — re-run no-op)

## To add manually (browser-side / reviewer-grade)
- [ ] Full CloudWatch dashboard screenshot (with chrome / titles / time range visible)
- [ ] cloud-smoke 7/7 terminal output (paste into smoke.txt or screenshot)
- [ ] AWS Client VPN handshake confirmation (Tunnelblick log or 'tunnelblick status')
- [ ] AWS Console VPC topology screenshot (showing aegis-enclave-* tagged resources)

## Cloud-acceptance cost-window markers (per ADR-0034)
- Apply started:    (fill in from cloud-up.sh start time)
- Smoke completed:  (fill in)
- Evidence captured (this script ran): $TS
- Destroy started:  (fill in from cloud-down.sh start time — within the bounded window)
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
