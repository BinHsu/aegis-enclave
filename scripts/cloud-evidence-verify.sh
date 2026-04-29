#!/usr/bin/env bash
# cloud-evidence-verify.sh — gate before `make cloud-down`.
#
# Per memory feedback_phase25_screenshot_evidence.md: 'terraform destroy' is
# irreversible. cloud-evidence.sh captures the API-fetchable subset; this
# script verifies that what was captured is COMPLETE, NON-EMPTY, and
# semantically VALID before the destroy window closes.
#
# Catches:
#   - Missing expected file (cloud-evidence skipped a panel)
#   - PNG too small (<8KB heuristic — likely a "no data" sparse image)
#   - JSON malformed or missing key fields (network error returned XML/HTML)
#   - DDB Global Tables describe-table missing Replicas[] (replication not
#     actually configured at apply time)
#   - Route53 health-check status not "Success" (active-active not healthy)
#   - Worker log empty (no executions hit the worker → smoke generated no load)
#
# Optional manual artifacts (multi-region):
#   - VPN handshake (wg show OR utun interface) per region
#   - DDB describe-table per region (Replicas[] active-active proof)
#   - Route53 health-check status per region
#
# Exit codes:
#   0 — all expected artifacts pass
#   1 — at least one FAIL
#   2 — no evidence directory found (cloud-evidence.sh hasn't run)

set -euo pipefail

if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    readonly RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m'
    readonly BLUE=$'\033[34m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi
pass()    { printf "${GREEN}✓${RESET} %s\n" "$*"; }
fail()    { printf "${RED}✗${RESET} %s\n" "$*" >&2; FAILED=$((FAILED+1)); }
warn()    { printf "${YELLOW}⚠${RESET} %s\n" "$*" >&2; }
info()    { printf "${BLUE}→${RESET} %s\n" "$*"; }
section() { printf "\n${BOLD}── %s ──${RESET}\n" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_ROOT="$REPO_ROOT/evidence"

if [[ ! -d "$EVIDENCE_ROOT" ]]; then
    printf "${RED}No evidence/ directory. Run 'make cloud-evidence' first.${RESET}\n" >&2
    exit 2
fi

# Find latest evidence dir (UTC-timestamped subdirectory)
EVIDENCE_DIR="${EVIDENCE_DIR:-$(find "$EVIDENCE_ROOT" -maxdepth 1 -type d -name '20*' | sort | tail -1)}"

if [[ -z "$EVIDENCE_DIR" || ! -d "$EVIDENCE_DIR" ]]; then
    printf "${RED}No timestamped evidence directory under %s${RESET}\n" "$EVIDENCE_ROOT" >&2
    exit 2
fi

info "verifying $EVIDENCE_DIR"

FAILED=0
# Heuristic threshold for CloudWatch get-metric-widget-image PNGs.
# A "no data" widget renders as ~3-5KB (chrome only, no plot lines).
# Active widgets with data are typically 10-30KB+.
PNG_MIN_BYTES=${PNG_MIN_BYTES:-8000}

# ─── 1) CloudWatch metric panel PNGs (per-region subfolders) ─────────────
# Naming scheme (matches cloud-evidence.sh): metrics-<region>/<panel>.png.
# Primary region MUST exist with all 6 panels; secondary region (if present)
# is best-effort — only SQS + DDB panels expected since not all ECS / Valkey /
# ALB dimensions are exported per-region in outputs.tf.
section "Metric panel PNGs (per-region; >= ${PNG_MIN_BYTES} bytes — non-sparse)"

shopt -s nullglob
metric_dirs=("$EVIDENCE_DIR"/metrics-*/)
shopt -u nullglob
if [[ ${#metric_dirs[@]} -eq 0 ]]; then
    fail "no metrics-<region>/ subfolders found (cloud-evidence.sh must run before verify)"
fi

primary_panels=(
    01-sqs-visible.png
    02-ecs-worker-utilization.png
    03-elasticache-bytes.png
    04-elasticache-ecpu.png
    05-alb-target-response-time.png
    06-ddb-throttles.png
)
secondary_panels=(
    01-sqs-visible.png
    06-ddb-throttles.png
)

# First metrics-* dir alphabetically = treat as primary (all 6 required); the
# rest as secondary (best-effort: SQS + DDB required, others may be absent).
primary_dir="${metric_dirs[0]}"
primary_region=$(basename "$primary_dir" | sed -E 's/^metrics-//')
info "primary metrics dir (full panel set required): $primary_dir"

for panel in "${primary_panels[@]}"; do
    f="$primary_dir$panel"
    if [[ ! -f "$f" ]]; then
        fail "$primary_region/$panel — missing"
        continue
    fi
    size=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f")
    if [[ "$size" -lt "$PNG_MIN_BYTES" ]]; then
        fail "$primary_region/$panel — only ${size} bytes (likely 'no data' sparse render)"
    else
        pass "$primary_region/$panel — ${size} bytes"
    fi
done

# Secondary regions (if any) — best-effort: SQS + DDB required, others tolerated absent.
for ((i=1; i<${#metric_dirs[@]}; i++)); do
    sec_dir="${metric_dirs[$i]}"
    sec_region=$(basename "$sec_dir" | sed -E 's/^metrics-//')
    info "secondary metrics dir (SQS + DDB required, others tolerated absent): $sec_dir"
    for panel in "${secondary_panels[@]}"; do
        f="$sec_dir$panel"
        if [[ ! -f "$f" ]]; then
            fail "$sec_region/$panel — missing"
            continue
        fi
        size=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f")
        if [[ "$size" -lt "$PNG_MIN_BYTES" ]]; then
            fail "$sec_region/$panel — only ${size} bytes (likely 'no data' sparse render)"
        else
            pass "$sec_region/$panel — ${size} bytes"
        fi
    done
done

# ─── 2) Worker + bootstrap logs (non-empty; region-suffixed) ─────────────
# Naming scheme: worker-<region>.log + bootstrap-<region>.log.
# Glob matches all regions captured by cloud-evidence.sh.
section "CloudWatch log excerpts (region-suffixed)"

shopt -s nullglob
worker_logs=("$EVIDENCE_DIR"/logs/worker-*.log)
bootstrap_logs=("$EVIDENCE_DIR"/logs/bootstrap-*.log)
shopt -u nullglob

if [[ ${#worker_logs[@]} -eq 0 ]]; then
    fail "no worker-*.log files in $EVIDENCE_DIR/logs/"
fi
if [[ ${#bootstrap_logs[@]} -eq 0 ]]; then
    fail "no bootstrap-*.log files in $EVIDENCE_DIR/logs/"
fi

for f in "${worker_logs[@]}" "${bootstrap_logs[@]}"; do
    name=$(basename "$f")
    # Empty FilterLogEvents returns '{"events":[],"searchedLogStreams":[]}' (~50 bytes)
    size=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f")
    if [[ "$size" -lt 200 ]]; then
        fail "$name — only ${size} bytes (likely empty events array; logs not generated or wrong log group)"
    else
        if command -v jq >/dev/null 2>&1; then
            event_count=$(jq -r '.events | length' "$f" 2>/dev/null || echo "?")
            pass "$name — ${size} bytes, ${event_count} events"
        else
            pass "$name — ${size} bytes"
        fi
    fi
done

# ─── 3) terraform-output.json ────────────────────────────────────────────
section "Terraform output snapshot"

f="$EVIDENCE_DIR/terraform-output.json"
if [[ ! -f "$f" ]]; then
    fail "terraform-output.json — missing"
elif ! jq empty "$f" 2>/dev/null; then
    fail "terraform-output.json — malformed JSON"
else
    if jq -e '.dynamodb_table_name.value' "$f" >/dev/null 2>&1; then
        pass "terraform-output.json — has dynamodb_table_name"
    else
        fail "terraform-output.json — missing dynamodb_table_name field"
    fi
fi

# ─── 4) Multi-region manual artifacts (warn-only if missing) ─────────────
# Filename scheme matches cloud-evidence.sh:
#   ddb-<region>.json (full region string, forker-portable)
#   r53-hc-<key>-<id>-status.json (key = primary | secondary; id = HC ID)
#   vpn-utun.txt (always written by cloud-evidence.sh; empty body OK)
section "Multi-region manual artifacts (Route53 health, DDB Global Tables, VPN)"

# DDB describe-table — glob on full region string. Single-region scope = 1
# file (Replicas[] empty is acceptable then). Multi-region = ≥ 2 files,
# Replicas[] must be non-empty.
shopt -s nullglob
ddb_files=("$EVIDENCE_DIR"/ddb-*.json)
shopt -u nullglob
if [[ ${#ddb_files[@]} -eq 0 ]]; then
    warn "no ddb-<region>.json found (cloud-evidence.sh skipped — dynamodb_table_name output missing?)"
else
    multi_region=$(( ${#ddb_files[@]} >= 2 ))
    for f in "${ddb_files[@]}"; do
        name=$(basename "$f")
        if ! jq empty "$f" 2>/dev/null; then
            fail "$name — malformed JSON"
            continue
        fi
        replica_count=$(jq -r '.Table.Replicas | length // 0' "$f" 2>/dev/null || echo 0)
        if [[ $multi_region -eq 1 ]] && [[ "$replica_count" -lt 1 ]]; then
            fail "$name — Replicas[] empty (Global Tables NOT configured at this region's view)"
        elif [[ "$replica_count" -ge 1 ]]; then
            replica_regions=$(jq -r '[.Table.Replicas[].RegionName] | join(",")' "$f" 2>/dev/null)
            pass "$name — ${replica_count} replica(s): ${replica_regions}"
        else
            pass "$name — single-region scope (Replicas[] empty as expected)"
        fi
    done
fi

# Route53 health checks — filename pattern r53-hc-*-status.json (key prefix
# variant) or r53-hc-*.json (legacy). Match both.
shopt -s nullglob
hc_files=("$EVIDENCE_DIR"/r53-hc-*.json)
shopt -u nullglob
if [[ ${#hc_files[@]} -eq 0 ]]; then
    warn "Route53 health-check JSON not present (multi-region disabled or route53_zone_name empty in tfvars — graceful skip)"
else
    for f in "${hc_files[@]}"; do
        name=$(basename "$f")
        if ! jq empty "$f" 2>/dev/null; then
            fail "$name — malformed JSON"
            continue
        fi
        # get-health-check-status returns HealthCheckObservations[].StatusReport.Status
        # Most recent observation's status:
        recent_status=$(jq -r '.HealthCheckObservations | sort_by(.StatusReport.CheckedTime) | last | .StatusReport.Status // "unknown"' "$f" 2>/dev/null)
        if [[ "$recent_status" == *"Success"* ]]; then
            pass "$name — most-recent observation: ${recent_status}"
        else
            fail "$name — most-recent observation: ${recent_status} (expected Success)"
        fi
    done
fi

# VPN handshake — vpn-utun.txt always captured by cloud-evidence.sh. Empty
# body (just header lines, ~200 bytes) documents "no active tunnel at
# evidence time" — that's valid documentation, not a failure.
shopt -s nullglob
vpn_files=("$EVIDENCE_DIR"/vpn-*.txt)
shopt -u nullglob
if [[ ${#vpn_files[@]} -eq 0 ]]; then
    fail "VPN tunnel evidence not captured (cloud-evidence.sh must write vpn-utun.txt)"
else
    for f in "${vpn_files[@]}"; do
        name=$(basename "$f")
        size=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f")
        # ~50 byte = literally empty file (didn't even write header). Real
        # captured-empty file with header is ~200+ bytes.
        if [[ "$size" -lt 50 ]]; then
            fail "$name — only ${size} bytes (cloud-evidence.sh did not write the header)"
        else
            pass "$name — ${size} bytes"
        fi
    done
fi

# ─── 5) Summary ──────────────────────────────────────────────────────────
section "Summary"

if [[ "$FAILED" -gt 0 ]]; then
    printf "\n${RED}${BOLD}%d FAIL%s${RESET} — DO NOT run 'make cloud-down' until evidence is complete.\n" "$FAILED" "$([ "$FAILED" -gt 1 ] && echo "s" || echo "")"
    printf "${YELLOW}Common fixes:${RESET}\n"
    printf "  - Re-run 'make cloud-evidence' after generating more smoke load (curl /primes a few more times)\n"
    printf "  - For PNG sparse data: CloudWatch metric aggregation has ~30s lag — wait + re-capture\n"
    printf "  - For DDB Replicas empty: replica creation may still be in PROVISIONING state — check 'aws dynamodb describe-table --region <r> --query Table.Replicas[].ReplicaStatus'\n"
    printf "  - For Route53 health Failure: check ALB has at least one healthy ECS task (HealthyHostCount metric)\n"
    exit 1
fi

printf "\n${GREEN}${BOLD}all evidence verified${RESET} — safe to proceed to cloud-down\n"
exit 0
