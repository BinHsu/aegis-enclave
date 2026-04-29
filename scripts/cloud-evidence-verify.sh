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

# ─── 1) CloudWatch metric panel PNGs ─────────────────────────────────────
section "Metric panel PNGs (>= ${PNG_MIN_BYTES} bytes — non-sparse)"

for panel in \
    01-sqs-visible.png \
    02-ecs-worker-utilization.png \
    03-elasticache-bytes.png \
    04-elasticache-ecpu.png \
    05-alb-target-response-time.png \
    06-ddb-throttles.png; do
    f="$EVIDENCE_DIR/metrics/$panel"
    if [[ ! -f "$f" ]]; then
        fail "$panel — missing"
        continue
    fi
    size=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f")
    if [[ "$size" -lt "$PNG_MIN_BYTES" ]]; then
        fail "$panel — only ${size} bytes (likely 'no data' sparse render; smoke didn't generate metric or panel widget JSON dimensions are wrong)"
    else
        pass "$panel — ${size} bytes"
    fi
done

# ─── 2) Worker + bootstrap logs (non-empty) ──────────────────────────────
section "CloudWatch log excerpts"

for logfile in worker.log bootstrap.log; do
    f="$EVIDENCE_DIR/logs/$logfile"
    if [[ ! -f "$f" ]]; then
        fail "$logfile — missing"
        continue
    fi
    # Empty FilterLogEvents returns '{"events":[],"searchedLogStreams":[]}' (~50 bytes)
    size=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f")
    if [[ "$size" -lt 200 ]]; then
        fail "$logfile — only ${size} bytes (likely empty events array; logs not generated or wrong log group)"
    else
        # Try to count events if jq is available
        if command -v jq >/dev/null 2>&1; then
            event_count=$(jq -r '.events | length' "$f" 2>/dev/null || echo "?")
            pass "$logfile — ${size} bytes, ${event_count} events"
        else
            pass "$logfile — ${size} bytes"
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
section "Multi-region manual artifacts (Route53 health, DDB Global Tables, VPN)"

# DDB describe-table both regions
for desc in ddb-fra.json ddb-ire.json; do
    f="$EVIDENCE_DIR/$desc"
    if [[ ! -f "$f" ]]; then
        warn "$desc — not present (run 'aws dynamodb describe-table --region <r> --table-name aegis-enclave-executions > $f' before cloud-down)"
        continue
    fi
    if ! jq empty "$f" 2>/dev/null; then
        fail "$desc — malformed JSON"
        continue
    fi
    replica_count=$(jq -r '.Table.Replicas | length' "$f" 2>/dev/null || echo 0)
    if [[ "$replica_count" -lt 1 ]]; then
        fail "$desc — Replicas[] empty (Global Tables NOT configured at this region's view)"
    else
        replica_regions=$(jq -r '[.Table.Replicas[].RegionName] | join(",")' "$f" 2>/dev/null)
        pass "$desc — ${replica_count} replica(s): ${replica_regions}"
    fi
done

# Route53 health checks
shopt -s nullglob
hc_files=("$EVIDENCE_DIR"/r53-hc-*.json)
shopt -u nullglob
if [[ ${#hc_files[@]} -eq 0 ]]; then
    warn "Route53 health-check JSON not present (per cloud-up runbook step 5)"
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

# VPN handshake (at least one tunnel proof)
shopt -s nullglob
vpn_files=("$EVIDENCE_DIR"/vpn-*.txt)
shopt -u nullglob
if [[ ${#vpn_files[@]} -eq 0 ]]; then
    warn "VPN handshake (wg show / utun ifconfig) not captured — capture from at least one region tunnel before cloud-down"
else
    for f in "${vpn_files[@]}"; do
        name=$(basename "$f")
        size=$(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f")
        if [[ "$size" -lt 50 ]]; then
            fail "$name — only ${size} bytes"
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
