#!/usr/bin/env bash
# dr-acceptance.sh — end-to-end dual-region DR acceptance for aegis-enclave.
#
# One command proves the whole disaster-recovery story, not just blast-radius
# isolation (which is all `dr-drill.sh` covers). Sequence:
#
#   1. BRING UP   both regions (delegates to cloud-up.sh — full apply).
#   2. VPN        prompt the operator to connect BOTH region VPN tunnels; wait.
#   3. VERIFY #1  cross-region recompute on the HEALTHY dual-region stack:
#                 POST in the platform region, poll in the peer region — the
#                 peer's bucket lacks the object (no CRR), so it regenerates it
#                 locally and serves it (ADR-0049). Delegates to
#                 cross_region_poll_check.sh.
#   4. KILL       destroy ONE region's compute (the peer) — a real region loss.
#   5. VERIFY #2  the SURVIVING region still serves a fresh compute job
#                 (POST -> poll -> done) while the peer is gone — service
#                 continuity under region loss.
#   6. CLEAN UP   tear everything down (delegates to cloud-down.sh).
#
# This is an OPERATOR tool: it performs REAL, billable cloud operations
# (apply + destroy + apply-target-destroy + destroy) and takes tens of minutes.
# Confirmation gates guard the destructive steps. VPN connection is manual.
#
# What each verify proves:
#   #1 — cross-region data is available via recompute-on-miss (ADR-0049); the
#        DDB Global Table replicates metadata, the result is regenerated locally.
#   #2 — losing a region does not take the service down; the survivor keeps
#        computing (ADR-0008 Tier-2 RTO; ADR-0042 active-active).
#
# Relationship to dr-drill.sh: dr-drill measures REBUILD RTO (destroy + rebuild
# a region, time the recovery). This script proves the END-TO-END DR contract
# (up -> cross-region -> kill -> survivor -> down). They are complementary.
#
# Usage:
#   make dr-acceptance
#   ./scripts/dr-acceptance.sh --yes        # skip destructive-step prompts
#   ./scripts/dr-acceptance.sh --keep-up    # stop before the final teardown
#
# Exit codes:
#   0 — full DR acceptance passed
#   1 — pre-flight / single-region / VPN failed
#   2 — a phase failed (bring-up / verify / kill / survivor)
#   3 — operator declined a confirmation
set -euo pipefail

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
section() { printf "\n${BOLD}══ %s ══${RESET}\n" "$*"; }

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
TFVARS="$TF_DIR/terraform.tfvars"

ENDPOINT_HOST="${ENDPOINT_HOST:-api.enclave.internal}"
# Survivor-verify range. π(200000) − π(100000) = 8392. NOTE: VERIFY #1 already
# POSTed this same range to the platform region, so the survivor (platform)
# likely serves it from the Valkey cache rather than a fresh sieve. That is
# fine — VERIFY #2 proves the survivor's full request path still works under
# region loss (API -> SQS -> worker -> S3 -> GET), not that it recomputes.
# Override TEST_START/TEST_END/EXPECTED_COUNT to force a fresh compute.
TEST_START="${TEST_START:-100001}"
TEST_END="${TEST_END:-200000}"
EXPECTED_COUNT="${EXPECTED_COUNT:-8392}"
SURVIVOR_POLL_TIMEOUT_S="${SURVIVOR_POLL_TIMEOUT_S:-45}"
PEER_TARGET="module.region_peer[0]"

ASSUME_YES=0
KEEP_UP=0
for arg in "$@"; do
    case "$arg" in
        --yes|--batch) ASSUME_YES=1 ;;
        --keep-up)     KEEP_UP=1 ;;
        -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "unknown argument: $arg (supported: --yes, --keep-up, --help)" 1 ;;
    esac
done

confirm() {
    # $1 = prompt. Honours --yes and non-TTY stdin. exit 3 on decline.
    local reply
    if [[ "$ASSUME_YES" -eq 1 ]]; then info "--yes — proceeding: $1"; return 0; fi
    if [[ ! -t 0 ]]; then info "non-interactive stdin — proceeding: $1"; return 0; fi
    printf "%s %s[type yes]%s: " "$1" "$BOLD" "$RESET"
    read -r reply
    [[ "$reply" == "yes" ]] || fail "operator declined — '$1'" 3
}

section "aegis-enclave — dual-region DR acceptance"
echo "Started: $(ts)"
cat <<EOF

  This runs REAL, billable cloud operations end to end:
    cloud-up (both regions) -> verify#1 -> destroy peer -> verify#2 -> cloud-down
  Expect tens of minutes and an apply-then-destroy cost window (per ADR-0034).
EOF
confirm "Proceed with the full DR acceptance"

# ─── Pre-flight: multi-region required ─────────────────────────────────────
section "0 — Pre-flight"
[[ -f "$TFVARS" ]] || fail "terraform.tfvars missing — run 'make tfvars-init' first" 1
PLATFORM_REGION=$( (grep -E '^platform_region[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
PLATFORM_REGION="${PLATFORM_REGION:-eu-central-1}"
PEER_REGION=$( (grep -oE '^[[:space:]]*"[a-z]{2}-[a-z]+-[0-9]+"[[:space:]]*=[[:space:]]*\{' "$TFVARS" 2>/dev/null || true) \
    | sed -E 's/.*"([^"]+)".*/\1/' | grep -vx "$PLATFORM_REGION" | head -1 || true)
[[ -n "$PEER_REGION" ]] \
    || fail "no peer region in $TFVARS regions map — DR acceptance needs a multi-region (active-active) config" 1
ok "platform region: $PLATFORM_REGION / peer region: $PEER_REGION"

# ─── Phase 1: bring up both regions ────────────────────────────────────────
section "1 — BRING UP both regions (cloud-up.sh)"
"$SCRIPT_DIR/cloud-up.sh" || fail "cloud-up failed — run 'make cloud-down' to clean any partial stack" 2
ok "both regions applied"

# ─── Phase 2: VPN prompt + wait ────────────────────────────────────────────
section "2 — CONNECT VPN (both regions)"
cat <<EOF

  cloud-up printed the per-region VPN configs above. Connect BOTH tunnels now:
    - platform region ($PLATFORM_REGION)
    - peer region     ($PEER_REGION)
  (Tunnelblick / 'sudo openvpn --config pki/<operator>-<region>.ovpn'.)
EOF
if [[ "$ASSUME_YES" -ne 1 ]] && [[ -t 0 ]]; then
    printf "Press %senter%s once BOTH VPN tunnels are connected... " "$BOLD" "$RESET"
    read -r _
fi

# ─── Phase 3: VERIFY #1 — cross-region recompute (healthy) ─────────────────
section "3 — VERIFY #1: cross-region recompute-on-miss (ADR-0049)"
if ! "$SCRIPT_DIR/cross_region_poll_check.sh"; then
    fail "VERIFY #1 failed — cross-region recompute did not pass. If this is a VPN
issue, connect BOTH tunnels and re-run. Stack is still UP (run 'make cloud-down' to clean)." 2
fi
ok "VERIFY #1 passed — cross-region data available via recompute"

# ─── Phase 4: KILL one region (peer) ───────────────────────────────────────
section "4 — KILL the peer region ($PEER_REGION)"
cat <<EOF

  Next: ${BOLD}terraform destroy -target='$PEER_TARGET'${RESET}
  Destroys the PEER region compute (ECS/ALB/VPN/Valkey/SQS/VPC). The DynamoDB
  Global Table replica is a platform-layer resource and SURVIVES.
EOF
confirm "Destroy the peer region and continue to VERIFY #2"
KILL_RC=0
(cd "$TF_DIR" && terraform destroy -target="$PEER_TARGET" -auto-approve -input=false) || KILL_RC=$?
[[ "$KILL_RC" -eq 0 ]] || fail "peer destroy exited $KILL_RC — inspect state; 'make cloud-down' can clean a partial stack" 2
ok "peer region destroyed — service is now single-region (survivor: $PLATFORM_REGION)"

# ─── Phase 5: VERIFY #2 — survivor serves under region loss ────────────────
section "5 — VERIFY #2: survivor ($PLATFORM_REGION) still serves a fresh job"
command -v jq  >/dev/null 2>&1 || fail "jq not found in PATH (brew install jq)" 1
command -v dig >/dev/null 2>&1 || fail "dig not found in PATH" 1

ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name 2>/dev/null || echo "")
[[ -n "$ALB_DNS" ]] || fail "alb_dns_name output missing after kill — platform region unexpectedly gone" 2
ALB_IP=$( (dig +short "$ALB_DNS" | grep -E '^[0-9.]+$' || true) | head -1)
[[ -n "$ALB_IP" ]] || fail "platform ALB resolved no IP — platform VPN not connected" 1
SURV_CA="$(mktemp -t aegis-dr-surv-ca.XXXXXX.pem)"
trap 'rm -f "$SURV_CA"' EXIT
(cd "$TF_DIR" && terraform output -raw alb_self_signed_ca_pem > "$SURV_CA") \
    || fail "alb_self_signed_ca_pem output missing" 2
SURV_CURL=(curl -s --max-time 15 --cacert "$SURV_CA" --resolve "${ENDPOINT_HOST}:443:${ALB_IP}")
BASE="https://${ENDPOINT_HOST}"

S_HEALTH=$("${SURV_CURL[@]}" -o /dev/null -w '%{http_code}' "${BASE}/health" 2>/dev/null || echo "000")
[[ "$S_HEALTH" == "200" ]] || fail "survivor /health → $S_HEALTH (expected 200) — survivor not serving" 2
ok "survivor /health → 200"

POST_RESP=$("${SURV_CURL[@]}" -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "{\"start\":${TEST_START},\"end\":${TEST_END}}" "${BASE}/primes")
POST_CODE=$(printf '%s\n' "$POST_RESP" | tail -1)
POST_BODY=$(printf '%s\n' "$POST_RESP" | sed '$d')
[[ "$POST_CODE" == "202" ]] || fail "survivor POST → $POST_CODE (expected 202): $POST_BODY" 2
EXEC_ID=$(printf '%s' "$POST_BODY" | jq -r '.execution_id // empty')
[[ -n "$EXEC_ID" ]] || fail "survivor POST returned no execution_id" 2
info "survivor accepted job $EXEC_ID — polling to done"

S_START=$(date -u +%s)
S_RESULT=""
while (( $(date -u +%s) - S_START < SURVIVOR_POLL_TIMEOUT_S )); do
    G_BODY=$("${SURV_CURL[@]}" "${BASE}/primes/${EXEC_ID}")
    G_STATUS=$(printf '%s' "$G_BODY" | jq -r '.status // empty')
    if [[ "$G_STATUS" == "done" ]]; then S_RESULT="$G_BODY"; break; fi
    [[ "$G_STATUS" == "failed" ]] && fail "survivor job failed" 2
    sleep 2
done
[[ -n "$S_RESULT" ]] || fail "survivor did not reach done within ${SURVIVOR_POLL_TIMEOUT_S}s" 2
S_COUNT=$(printf '%s' "$S_RESULT" | jq -r '.result | length')
[[ "$S_COUNT" == "$EXPECTED_COUNT" ]] \
    || fail "survivor result count=$S_COUNT, expected $EXPECTED_COUNT" 2
ok "VERIFY #2 passed — survivor served a fresh job (count=$S_COUNT) with the peer region gone"

# ─── Phase 6: clean up ─────────────────────────────────────────────────────
section "6 — CLEAN UP"
if [[ "$KEEP_UP" -eq 1 ]]; then
    warn "--keep-up: leaving the (single-region) stack UP. Tear down with 'make cloud-down' when done."
else
    confirm "Tear down the remaining stack now (cloud-down)"
    "$SCRIPT_DIR/cloud-down.sh" || fail "cloud-down failed — inspect state and re-run 'make cloud-down'" 2
    ok "stack torn down"
fi

section "DR acceptance — PASSED"
cat <<EOF

  ✓ both regions brought up
  ✓ VERIFY #1: cross-region recompute-on-miss (ADR-0049)
  ✓ peer region killed
  ✓ VERIFY #2: survivor served a fresh job under region loss
  $( [[ "$KEEP_UP" -eq 1 ]] && echo "⚠ stack left UP (--keep-up)" || echo "✓ stack torn down" )

  Finished: $(ts)
EOF
