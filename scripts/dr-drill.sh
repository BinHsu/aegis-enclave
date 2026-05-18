#!/usr/bin/env bash
# dr-drill.sh — disaster-recovery drill harness for aegis-enclave.
#
# Measures region-loss recovery RTO and proves the surviving region keeps
# serving throughout a partial-region outage.
#
# This is an OPERATOR tool. It performs REAL cloud operations (terraform
# destroy + apply against a deployed stack). Run it DURING the cloud-acceptance
# window, AFTER `make cloud-up`, with the operator VPN-connected to the
# PLATFORM region.
#
# What it does (each phase is timed):
#   1. PRE-FLIGHT   verify terraform state, AWS auth, platform-region ALB reach
#   2. BASELINE     probe platform-region ALB /health once → expect 200
#   3. TEARDOWN     terraform destroy -target='module.region_peer[0]'
#                   (peer compute only; DynamoDB Global Table replica is a
#                    platform-layer resource and deliberately SURVIVES — a
#                    realistic partial outage where the managed data layer
#                    outlives the compute region)
#   4. SURVIVOR-PROBE  runs concurrently with TEARDOWN + REBUILD; every ~15s
#                   curls the platform ALB /health, tallies 200 vs failures
#   5. REBUILD      terraform apply (full regions map, no -target) → peer back
#   6. RECONVERGE   poll the peer region's ECS service via the AWS API until
#                   runningCount == desiredCount (no VPN switch needed)
#   7. REPORT       logs/dr-report-<UTC>.md + logs/dr-probe-<UTC>.log + stdout
#
# The terraform destroy in phase 3 is gated behind an explicit confirmation
# prompt (interactive). Use --yes / --batch (or a non-TTY stdin) to bypass.
#
# Usage:
#   make dr-drill
#   ./scripts/dr-drill.sh --yes        # unattended (skip confirmation)
#
# Exit codes:
#   0 — drill completed; report written
#   1 — pre-flight failed (state / auth / VPN)
#   2 — a drill phase failed (teardown / rebuild / reconverge)
#   3 — operator declined the teardown confirmation

set -euo pipefail

# ─── Colour output (degrades cleanly if NO_COLOR or non-TTY) ───────────────
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    readonly RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m'
    readonly BLUE=$'\033[34m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi
ok()      { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}⚠${RESET} %s\n" "$*" >&2; }
fail()    { printf "${RED}✗${RESET} %s\n" "$*" >&2; exit "${2:-2}"; }
info()    { printf "${BLUE}→${RESET} %s\n" "$*"; }
section() { printf "\n${BOLD}── %s ──${RESET}\n" "$*"; }

# ─── Timing primitives (locked spec) ───────────────────────────────────────
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { date -u +%s; }
dur() { printf '%dm %ds' $(( ($2 - $1) / 60 )) $(( ($2 - $1) % 60 )); }

# ─── Argument parsing ──────────────────────────────────────────────────────
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --yes|--batch) ASSUME_YES=1 ;;
        -h|--help)
            sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) fail "unknown argument: $arg (supported: --yes, --batch, --help)" 1 ;;
    esac
done

# ─── Locate repo + Terraform dir ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
TFVARS="$TF_DIR/terraform.tfvars"
LOG_DIR="$REPO_ROOT/logs"

# The terraform address for the peer region's compute stack. Destroying just
# this leaves the DynamoDB Global Table (root main.tf) intact — that is the
# whole point of the drill.
PEER_TARGET="module.region_peer[0]"

# Internal-ALB probe host. cloud-smoke.sh uses this default; an operator with a
# non-default alb_internal_hostname in tfvars can override via ENDPOINT_HOST.
ENDPOINT_HOST="${ENDPOINT_HOST:-api.enclave.internal}"

# SURVIVOR-PROBE cadence + RECONVERGE polling knobs (env-overridable).
PROBE_INTERVAL="${PROBE_INTERVAL:-15}"      # seconds between survivor probes
RECONVERGE_TIMEOUT="${RECONVERGE_TIMEOUT:-900}"   # max seconds to wait for peer ECS
RECONVERGE_INTERVAL="${RECONVERGE_INTERVAL:-20}"  # seconds between ECS polls

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_FILE="$LOG_DIR/dr-report-${STAMP}.md"
PROBE_LOG="$LOG_DIR/dr-probe-${STAMP}.log"

DRILL_START_TS="$(ts)"
DRILL_START="$(now)"

section "aegis-enclave — disaster-recovery drill"
echo "Started:     $DRILL_START_TS"
echo "Repo:        $REPO_ROOT"
echo "Terraform:   $TF_DIR"
echo "Peer target: $PEER_TARGET"
echo "Report:      $REPORT_FILE"

# ───────────────────────────────────────────────────────────────────────────
# Phase 1 — PRE-FLIGHT
# ───────────────────────────────────────────────────────────────────────────
section "1/7 — PRE-FLIGHT"
PRE_START="$(now)"

command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH" 1
command -v aws       >/dev/null 2>&1 || fail "aws CLI not found in PATH" 1
command -v dig       >/dev/null 2>&1 || fail "dig not found in PATH" 1
command -v curl      >/dev/null 2>&1 || fail "curl not found in PATH" 1
ok "terraform / aws / dig / curl present"

# Resolve AWS_PROFILE: env var > tfvars persisted > interactive prompt.
# Mirrors cloud-up.sh; subshell + || true per pipefail discipline.
if [[ -z "${AWS_PROFILE:-}" ]] && [[ -f "$TFVARS" ]]; then
    AWS_PROFILE_FROM_TFVARS=$( (grep -E '^aws_profile[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
    if [[ -n "$AWS_PROFILE_FROM_TFVARS" ]]; then
        export AWS_PROFILE="$AWS_PROFILE_FROM_TFVARS"
        info "Using AWS_PROFILE=$AWS_PROFILE (from $TFVARS)"
    fi
fi
if [[ -z "${AWS_PROFILE:-}" ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]] || [[ ! -t 0 ]]; then
        fail "AWS_PROFILE not set and no tfvars value — set AWS_PROFILE for unattended runs" 1
    fi
    PROFILES_AVAIL=$(aws configure list-profiles 2>/dev/null || true)
    if [[ -n "$PROFILES_AVAIL" ]]; then
        printf "Available AWS profiles:\n"
        echo "$PROFILES_AVAIL" | sed 's/^/  - /'
    fi
    printf "Enter AWS_PROFILE [default]: "
    read -r AWS_PROFILE_INPUT
    export AWS_PROFILE="${AWS_PROFILE_INPUT:-default}"
fi
info "Using AWS_PROFILE=$AWS_PROFILE"

# AWS auth must work — the drill leans on it for RECONVERGE.
aws sts get-caller-identity >/dev/null 2>&1 \
    || fail "aws sts get-caller-identity failed for profile '$AWS_PROFILE' — refresh creds (SSO login?) and retry" 1
ok "AWS auth OK (profile $AWS_PROFILE)"

# Terraform state must hold a deployed stack — alb_dns_name proves cloud-up ran.
ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name 2>/dev/null || echo "")
[[ -n "$ALB_DNS" ]] || fail "alb_dns_name output missing — no deployed stack. Run 'make cloud-up' first." 1
ok "platform ALB DNS: $ALB_DNS"

# Peer region must actually be in state — a single-region deploy has nothing
# for the drill to fail over. secondary_ecs_cluster_name is null when single.
PEER_ECS_CLUSTER=$(cd "$TF_DIR" && terraform output -raw secondary_ecs_cluster_name 2>/dev/null || echo "")
if [[ -z "$PEER_ECS_CLUSTER" || "$PEER_ECS_CLUSTER" == "null" ]]; then
    fail "no peer region in state (secondary_ecs_cluster_name is null) — drill needs a multi-region deploy" 1
fi
ok "peer ECS cluster: $PEER_ECS_CLUSTER"

# Determine the peer region from the regions map (the non-platform key).
PLATFORM_REGION=$( (grep -E '^platform_region[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
PLATFORM_REGION="${PLATFORM_REGION:-eu-central-1}"
PEER_REGION=$( (grep -oE '^[[:space:]]*"[a-z]{2}-[a-z]+-[0-9]+"[[:space:]]*=[[:space:]]*\{' "$TFVARS" 2>/dev/null || true) \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | grep -vx "$PLATFORM_REGION" \
    | head -1 || true )
[[ -n "$PEER_REGION" ]] || fail "could not determine peer region from regions map in $TFVARS" 1
ok "platform region: $PLATFORM_REGION / peer region: $PEER_REGION"

# Resolve the platform ALB private IP — empty means VPN is not connected.
ALB_IP=$( (dig +short "$ALB_DNS" | grep -E '^[0-9.]+$' || true) | head -1)
[[ -n "$ALB_IP" ]] || fail "platform ALB DNS resolved no IP — VPN not connected?
Connect the VPN to the PLATFORM region ($PLATFORM_REGION) and retry:
  sudo openvpn --config pki/<operator>-${PLATFORM_REGION}.ovpn" 1
ok "platform ALB resolved IP: $ALB_IP"

# Write the platform ALB CA to a temp file for the --cacert probe path.
CA_PEM="$(mktemp -t aegis-dr-ca.XXXXXX.pem)"
trap 'rm -f "$CA_PEM"' EXIT
(cd "$TF_DIR" && terraform output -raw alb_self_signed_ca_pem > "$CA_PEM") \
    || fail "alb_self_signed_ca_pem output missing" 1

# The probe command — same approach as cloud-smoke.sh (--cacert + --resolve).
PROBE_BASE="https://${ENDPOINT_HOST}"
probe_health() {
    # echoes the HTTP code (000 on connection failure); never aborts the script.
    curl -s --max-time 10 --cacert "$CA_PEM" \
        --resolve "${ENDPOINT_HOST}:443:${ALB_IP}" \
        -o /dev/null -w '%{http_code}' "${PROBE_BASE}/health" 2>/dev/null || echo "000"
}

# Confirm the platform ALB is actually serving before we start the drill.
PRE_HEALTH="$(probe_health)"
[[ "$PRE_HEALTH" == "200" ]] || fail "platform ALB /health returned $PRE_HEALTH (expected 200) — VPN down or stack unhealthy.
Verify with: make cloud-smoke" 1
ok "platform ALB /health → 200 (operator is on the VPN)"

PRE_END="$(now)"
ok "PRE-FLIGHT complete in $(dur "$PRE_START" "$PRE_END")"

# ───────────────────────────────────────────────────────────────────────────
# Phase 2 — BASELINE
# ───────────────────────────────────────────────────────────────────────────
section "2/7 — BASELINE"
BASELINE_START="$(now)"
BASELINE_CODE="$(probe_health)"
BASELINE_END="$(now)"
if [[ "$BASELINE_CODE" == "200" ]]; then
    ok "baseline: platform ALB /health → 200 (recorded)"
else
    fail "baseline probe returned $BASELINE_CODE (expected 200) — aborting before any teardown" 1
fi

# ───────────────────────────────────────────────────────────────────────────
# Confirmation gate — before any destructive action
# ───────────────────────────────────────────────────────────────────────────
section "Confirmation — TEARDOWN is a REAL cloud operation"
cat <<EOF

  The next phase runs:

    ${BOLD}terraform destroy -target='${PEER_TARGET}'${RESET}

  in $TF_DIR.

  This DESTROYS the PEER region ($PEER_REGION) compute stack:
    - ECS cluster / services / tasks
    - internal ALB + target groups
    - Client VPN endpoint
    - Valkey cache, SQS queue, VPC + endpoints

  It does NOT destroy:
    - the DynamoDB Global Table or its $PEER_REGION replica (platform-layer
      resource in root main.tf — deliberately survives the drill)
    - the PLATFORM region ($PLATFORM_REGION) stack

  REBUILD (phase 5) runs a full 'terraform apply' to bring the peer back.

EOF
if [[ "$ASSUME_YES" -eq 1 ]]; then
    info "--yes / --batch supplied — proceeding without prompt"
elif [[ ! -t 0 ]]; then
    info "non-interactive stdin detected — proceeding without prompt"
else
    printf "Type ${BOLD}yes${RESET} to destroy %s and run the drill: " "$PEER_TARGET"
    read -r CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        fail "operator declined — no cloud resources were touched" 3
    fi
fi
ok "confirmed — starting the drill"

# ───────────────────────────────────────────────────────────────────────────
# Phase 4 (started early) — SURVIVOR-PROBE background loop
# ───────────────────────────────────────────────────────────────────────────
# Started BEFORE teardown so it spans TEARDOWN + REBUILD. Writes a timestamped
# line per probe to $PROBE_LOG. Tally is computed afterwards from the log.
mkdir -p "$LOG_DIR"
: > "$PROBE_LOG"

survivor_probe_loop() {
    while true; do
        local code
        code="$(probe_health)"
        if [[ "$code" == "200" ]]; then
            printf '%s OK   %s /health -> %s\n' "$(ts)" "$ENDPOINT_HOST" "$code" >> "$PROBE_LOG"
        else
            printf '%s FAIL %s /health -> %s\n' "$(ts)" "$ENDPOINT_HOST" "$code" >> "$PROBE_LOG"
        fi
        sleep "$PROBE_INTERVAL"
    done
}

section "4/7 — SURVIVOR-PROBE (background; spans TEARDOWN + REBUILD)"
survivor_probe_loop &
PROBE_PID=$!
# Ensure the probe loop is reaped even if a later phase fails.
trap 'kill "$PROBE_PID" 2>/dev/null || true; rm -f "$CA_PEM"' EXIT
ok "survivor probe running (pid $PROBE_PID, every ${PROBE_INTERVAL}s) → $PROBE_LOG"

# ───────────────────────────────────────────────────────────────────────────
# Phase 3 — TEARDOWN
# ───────────────────────────────────────────────────────────────────────────
section "3/7 — TEARDOWN (destroy peer region compute)"
TEARDOWN_START="$(now)"
info "terraform destroy -target='$PEER_TARGET' -auto-approve"
TEARDOWN_RC=0
(cd "$TF_DIR" && terraform destroy -target="$PEER_TARGET" -auto-approve -input=false) || TEARDOWN_RC=$?
TEARDOWN_END="$(now)"
if [[ "$TEARDOWN_RC" -ne 0 ]]; then
    warn "terraform destroy exited $TEARDOWN_RC — peer compute may be partially destroyed"
    fail "TEARDOWN failed — inspect terraform state; 'make cloud-down' can clean a partial stack" 2
fi
ok "TEARDOWN complete in $(dur "$TEARDOWN_START" "$TEARDOWN_END") — peer region compute destroyed"

# ───────────────────────────────────────────────────────────────────────────
# Phase 5 — REBUILD
# ───────────────────────────────────────────────────────────────────────────
section "5/7 — REBUILD (full apply — bring the peer region back)"
REBUILD_START="$(now)"
info "terraform apply -auto-approve (full regions map, no -target)"
REBUILD_RC=0
(cd "$TF_DIR" && terraform apply -auto-approve -input=false) || REBUILD_RC=$?
REBUILD_END="$(now)"
if [[ "$REBUILD_RC" -ne 0 ]]; then
    warn "terraform apply exited $REBUILD_RC"
    fail "REBUILD failed — peer region not restored; inspect terraform output" 2
fi
ok "REBUILD complete in $(dur "$REBUILD_START" "$REBUILD_END")"

# ───────────────────────────────────────────────────────────────────────────
# Phase 6 — RECONVERGE
# ───────────────────────────────────────────────────────────────────────────
# Poll the peer region's ECS service via the AWS API (NOT a VPN probe — the
# operator stays connected to the platform region). runningCount == desiredCount
# and desiredCount > 0 means the peer compute has reconverged.
section "6/7 — RECONVERGE (poll peer ECS service via AWS API)"
RECONVERGE_START="$(now)"

# Re-read the peer cluster name post-rebuild (terraform output is authoritative).
PEER_ECS_CLUSTER=$(cd "$TF_DIR" && terraform output -raw secondary_ecs_cluster_name 2>/dev/null || echo "")
[[ -n "$PEER_ECS_CLUSTER" && "$PEER_ECS_CLUSTER" != "null" ]] \
    || fail "secondary_ecs_cluster_name missing after rebuild — peer region did not come back" 2
info "peer ECS cluster: $PEER_ECS_CLUSTER (region $PEER_REGION)"

RECONVERGED=0
while (( $(now) - RECONVERGE_START < RECONVERGE_TIMEOUT )); do
    # List service ARNs in the peer cluster. Subshell + || true: an empty list
    # mid-rebuild is legal and must not abort under pipefail.
    SERVICE_ARNS=$( (aws ecs list-services \
        --region "$PEER_REGION" --cluster "$PEER_ECS_CLUSTER" \
        --query 'serviceArns' --output text 2>/dev/null || true) )
    if [[ -z "$SERVICE_ARNS" ]]; then
        info "no ECS services registered yet — waiting ${RECONVERGE_INTERVAL}s"
        sleep "$RECONVERGE_INTERVAL"
        continue
    fi

    # describe-services returns running/desired per service. The drill is
    # converged when every service has desiredCount > 0 AND runningCount ==
    # desiredCount. Count mismatches; zero mismatch == stable.
    # shellcheck disable=SC2086
    COUNTS=$( (aws ecs describe-services \
        --region "$PEER_REGION" --cluster "$PEER_ECS_CLUSTER" \
        --services $SERVICE_ARNS \
        --query 'services[].{r:runningCount,d:desiredCount}' \
        --output text 2>/dev/null || true) )
    if [[ -z "$COUNTS" ]]; then
        info "describe-services returned nothing yet — waiting ${RECONVERGE_INTERVAL}s"
        sleep "$RECONVERGE_INTERVAL"
        continue
    fi

    PENDING=0
    SUMMARY=""
    # describe-services --output text yields one "running<TAB>desired" line per
    # service (the {r,d} projection orders keys alphabetically: d then r).
    while read -r D R; do
        [[ -z "${D:-}" ]] && continue
        SUMMARY="${SUMMARY} ${R}/${D}"
        if [[ "$D" -eq 0 || "$R" -ne "$D" ]]; then
            PENDING=$((PENDING + 1))
        fi
    done <<EOF
$COUNTS
EOF

    if [[ "$PENDING" -eq 0 ]]; then
        ok "peer ECS services stable (running/desired:${SUMMARY} )"
        RECONVERGED=1
        break
    fi
    info "peer ECS not stable yet (running/desired:${SUMMARY} ) — waiting ${RECONVERGE_INTERVAL}s"
    sleep "$RECONVERGE_INTERVAL"
done

RECONVERGE_END="$(now)"
if [[ "$RECONVERGED" -ne 1 ]]; then
    warn "peer ECS did not reach running==desired within ${RECONVERGE_TIMEOUT}s"
    # Non-fatal for the report — record it and continue to write the report.
fi
ok "RECONVERGE phase ended after $(dur "$RECONVERGE_START" "$RECONVERGE_END")"

# ───────────────────────────────────────────────────────────────────────────
# Stop the survivor probe + tally
# ───────────────────────────────────────────────────────────────────────────
kill "$PROBE_PID" 2>/dev/null || true
wait "$PROBE_PID" 2>/dev/null || true
trap 'rm -f "$CA_PEM"' EXIT

PROBE_TOTAL=$( (grep -c . "$PROBE_LOG" 2>/dev/null || true) )
PROBE_TOTAL="${PROBE_TOTAL:-0}"
PROBE_OK=$( (grep -c ' OK ' "$PROBE_LOG" 2>/dev/null || true) )
PROBE_OK="${PROBE_OK:-0}"
PROBE_FAIL=$( (grep -c ' FAIL ' "$PROBE_LOG" 2>/dev/null || true) )
PROBE_FAIL="${PROBE_FAIL:-0}"

# ───────────────────────────────────────────────────────────────────────────
# Phase 7 — REPORT
# ───────────────────────────────────────────────────────────────────────────
section "7/7 — REPORT"
DRILL_END="$(now)"
DRILL_END_TS="$(ts)"

PRE_DUR="$(dur "$PRE_START" "$PRE_END")"
TEARDOWN_DUR="$(dur "$TEARDOWN_START" "$TEARDOWN_END")"
REBUILD_DUR="$(dur "$REBUILD_START" "$REBUILD_END")"
RECONVERGE_DUR="$(dur "$RECONVERGE_START" "$RECONVERGE_END")"
TOTAL_DUR="$(dur "$DRILL_START" "$DRILL_END")"
# RTO = the recovery window: teardown start → peer reconverged.
RTO_DUR="$(dur "$TEARDOWN_START" "$RECONVERGE_END")"

RECONVERGE_RESULT="reconverged"
[[ "$RECONVERGED" -ne 1 ]] && RECONVERGE_RESULT="DID NOT reconverge within ${RECONVERGE_TIMEOUT}s"

cat > "$REPORT_FILE" <<EOF
# aegis-enclave — Disaster-Recovery Drill Report

| Field | Value |
|---|---|
| Drill start (UTC)  | $DRILL_START_TS |
| Drill end (UTC)    | $DRILL_END_TS |
| Platform region    | $PLATFORM_REGION |
| Peer region        | $PEER_REGION |
| Terraform target destroyed | \`$PEER_TARGET\` |
| Peer ECS cluster   | $PEER_ECS_CLUSTER |

## Scenario

Partial-region outage drill: the peer region's **compute stack** is destroyed
and rebuilt. The DynamoDB Global Table and its peer replica are platform-layer
resources (root \`main.tf\`) and deliberately **survive** — modelling a managed
data layer that outlives the lost compute region.

## Per-phase durations

| Phase | Duration |
|---|---|
| PRE-FLIGHT  | $PRE_DUR |
| TEARDOWN    | $TEARDOWN_DUR |
| REBUILD     | $REBUILD_DUR |
| RECONVERGE  | $RECONVERGE_DUR ($RECONVERGE_RESULT) |
| **Total drill** | **$TOTAL_DUR** |
| **Recovery RTO** (teardown start → peer reconverged) | **$RTO_DUR** |

## SURVIVOR-PROBE (platform region served throughout the peer outage)

The platform-region ALB \`/health\` was probed every ${PROBE_INTERVAL}s for the
full TEARDOWN + REBUILD + RECONVERGE window.

| Result | Count |
|---|---|
| HTTP 200 | $PROBE_OK |
| Failures (non-200 / connection) | $PROBE_FAIL |
| Total probes | $PROBE_TOTAL |

Baseline probe (before teardown): HTTP $BASELINE_CODE.

Raw probe lines: \`$(basename "$PROBE_LOG")\` (same directory).

## Interpretation

- A clean drill shows **0 survivor failures** — the surviving region keeps
  serving while the peer region is gone.
- The **Recovery RTO** above is the measured wall time to rebuild + reconverge
  the lost compute region.
EOF

ok "report written: $REPORT_FILE"
ok "raw probe log: $PROBE_LOG"

# ─── stdout summary ────────────────────────────────────────────────────────
section "Drill summary"
cat <<EOF

  Platform region:     $PLATFORM_REGION   (survivor)
  Peer region:         $PEER_REGION   (destroyed + rebuilt)
  Terraform target:    $PEER_TARGET

  PRE-FLIGHT:          $PRE_DUR
  TEARDOWN:            $TEARDOWN_DUR
  REBUILD:             $REBUILD_DUR
  RECONVERGE:          $RECONVERGE_DUR   ($RECONVERGE_RESULT)
  ─────────────────────────────────────────
  Recovery RTO:        $RTO_DUR
  Total drill:         $TOTAL_DUR

  Survivor probe:      $PROBE_OK × 200, $PROBE_FAIL × failure ($PROBE_TOTAL total)
  Baseline /health:    $BASELINE_CODE

  Report:              $REPORT_FILE
  Probe log:           $PROBE_LOG

EOF

if [[ "$PROBE_FAIL" -gt 0 ]]; then
    warn "survivor recorded $PROBE_FAIL failed probe(s) — the surviving region did NOT serve cleanly; investigate"
fi
if [[ "$RECONVERGED" -ne 1 ]]; then
    fail "peer region did not reconverge within ${RECONVERGE_TIMEOUT}s — drill incomplete" 2
fi

ok "DR drill complete"
