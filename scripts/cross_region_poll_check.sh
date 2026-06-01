#!/usr/bin/env bash
# cross_region_poll_check.sh — verify ADR-0049 recompute-on-cross-region-miss.
#
# This is the operator-driven cloud check for the one behaviour the local
# single-region stack CANNOT exercise: a result computed in the platform
# region, polled from the peer region, must be regenerated locally in the
# peer (its S3 bucket is independent — no CRR) and served within the client
# retry budget.
#
# Contract under test (ADR-0049 § Decision):
#   1. POST a compute range to the PLATFORM region  → 202 + execution_id.
#   2. Poll the platform region until status=done    → the result lands in
#      the platform bucket; the DDB row (Global Table) replicates to the peer.
#   3. Poll the PEER region for the same execution_id:
#        - the peer's DDB row says done, but the peer bucket lacks the object;
#        - the GET handler re-enqueues a local recompute and returns 503;
#        - the peer worker regenerates the object into the peer bucket;
#        - a subsequent poll returns 200 + the correct primes list.
#   The 503 (recompute-on-miss) is the ADR-0049 signature; observing it proves
#   the result was NOT pre-replicated (i.e. CRR is genuinely gone).
#
# Requires:
#   - BOTH region VPN tunnels connected (platform + peer) — the peer ALB is
#     reachable only via the peer region's Client VPN.
#   - terraform state present with multi-region outputs (secondary_alb_* set).
#   - jq + dig + terraform in PATH.
#
# Env overrides:
#   ENDPOINT_HOST   internal ALB hostname (default api.enclave.internal)
#   TEST_START/TEST_END/EXPECTED_COUNT   compute range + oracle count
#   RETRY_BUDGET_S  peer-side budget (default 90; reference client = 60)
#   POLL_INTERVAL_S peer poll interval (default 5)
#
# Exit codes: 0 pass · 1 pre-flight failed · 2 check failed
set -euo pipefail

if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    readonly RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m'
    readonly BLUE=$'\033[34m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi
ok()      { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}⚠${RESET} %s\n" "$*" >&2; }
fail()    { printf "${RED}✗${RESET} %s\n" "$*" >&2; exit 2; }
info()    { printf "${BLUE}→${RESET} %s\n" "$*"; }
section() { printf "\n${BOLD}── %s ──${RESET}\n" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
TFVARS="$TF_DIR/terraform.tfvars"

# Resolve AWS_PROFILE: env var > tfvars persisted (terraform output honours it).
if [[ -z "${AWS_PROFILE:-}" ]] && [[ -f "$TFVARS" ]]; then
    AWS_PROFILE_FROM_TFVARS=$( (grep -E '^aws_profile[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
    if [[ -n "$AWS_PROFILE_FROM_TFVARS" ]]; then
        export AWS_PROFILE="$AWS_PROFILE_FROM_TFVARS"
        info "Using AWS_PROFILE=$AWS_PROFILE (from $TFVARS)"
    fi
fi

ENDPOINT_HOST="${ENDPOINT_HOST:-api.enclave.internal}"
# Range OUTSIDE the bootstrap pre-warm [1, 100_000] so the platform region
# genuinely computes (and the peer genuinely has to recompute). π(200000) −
# π(100000) = 17984 − 9592 = 8392 (same oracle count as cloud-smoke step 1).
TEST_START="${TEST_START:-100001}"
TEST_END="${TEST_END:-200000}"
EXPECTED_COUNT="${EXPECTED_COUNT:-8392}"
RETRY_BUDGET_S="${RETRY_BUDGET_S:-90}"
POLL_INTERVAL_S="${POLL_INTERVAL_S:-5}"
PLATFORM_POLL_TIMEOUT_S="${PLATFORM_POLL_TIMEOUT_S:-30}"

section "aegis-enclave — cross-region recompute-on-miss check (ADR-0049)"

# ─── Pre-flight ───────────────────────────────────────────────────────────
section "0 — Pre-flight"
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH"
command -v jq        >/dev/null 2>&1 || fail "jq not found in PATH (brew install jq)"
command -v dig       >/dev/null 2>&1 || fail "dig not found in PATH"

# Build a region-pinned curl: resolves ENDPOINT_HOST to this region's ALB IP
# and trusts this region's self-signed CA. Echoes the curl array, one arg per
# line, for the caller to read into an array (bash 3.2 has no nameref).
resolve_region() {
    # $1 = dns output name, $2 = ca output name, $3 = human label
    local dns_out="$1" ca_out="$2" label="$3"
    local dns ip ca_file
    dns=$( (cd "$TF_DIR" && terraform output -raw "$dns_out" 2>/dev/null) || true)
    [[ -n "$dns" && "$dns" != "null" ]] \
        || fail "$dns_out output missing/null — is this a multi-region apply? Run 'make cloud-up' with a peer region set."
    ip=$( (dig +short "$dns" | grep -E '^[0-9.]+$' || true) | head -1)
    [[ -n "$ip" ]] \
        || fail "$label ALB ($dns) did not resolve to an IP — the $label region VPN tunnel is not connected.
Connect BOTH region VPNs (platform + peer) before running this check."
    ca_file="$(mktemp -t "aegis-${label}-ca.XXXXXX.pem")"
    _CA_FILES="${_CA_FILES:-} $ca_file"
    (cd "$TF_DIR" && terraform output -raw "$ca_out" > "$ca_file") \
        || fail "$ca_out output missing"
    info "$label ALB: $dns → $ip" >&2 # MUST be stderr: stdout is captured by the caller
    printf '%s\n' "$ip" "$ca_file"
}
_CA_FILES=""
cleanup() { for f in $_CA_FILES; do rm -f "$f"; done; }
trap cleanup EXIT

# Platform region (the write region).
PLAT_INFO=$(resolve_region alb_dns_name alb_self_signed_ca_pem platform)
PLAT_IP=$(printf '%s\n' "$PLAT_INFO" | sed -n '1p')
PLAT_CA=$(printf '%s\n' "$PLAT_INFO" | sed -n '2p')
PLAT_CURL=(curl -s --max-time 10 --cacert "$PLAT_CA" --resolve "${ENDPOINT_HOST}:443:${PLAT_IP}")

# Peer region (the cross-region read + recompute target).
PEER_INFO=$(resolve_region secondary_alb_dns_name secondary_alb_self_signed_ca_pem peer)
PEER_IP=$(printf '%s\n' "$PEER_INFO" | sed -n '1p')
PEER_CA=$(printf '%s\n' "$PEER_INFO" | sed -n '2p')
PEER_CURL=(curl -s --max-time 10 --cacert "$PEER_CA" --resolve "${ENDPOINT_HOST}:443:${PEER_IP}")

BASE="https://${ENDPOINT_HOST}"

# Connectivity probe on both regions.
P_HEALTH=$("${PLAT_CURL[@]}" -o /dev/null -w '%{http_code}' "${BASE}/health" 2>/dev/null || echo "000")
[[ "$P_HEALTH" == "200" ]] || fail "platform /health → $P_HEALTH (platform VPN down?)"
Q_HEALTH=$("${PEER_CURL[@]}" -o /dev/null -w '%{http_code}' "${BASE}/health" 2>/dev/null || echo "000")
[[ "$Q_HEALTH" == "200" ]] || fail "peer /health → $Q_HEALTH (peer VPN down?)"
ok "both regions reachable (/health → 200)"

# ─── Step 1: POST to the PLATFORM region ──────────────────────────────────
section "1 — POST [$TEST_START, $TEST_END] to platform region"
POST_RESP=$("${PLAT_CURL[@]}" -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "{\"start\":${TEST_START},\"end\":${TEST_END}}" "${BASE}/primes")
POST_CODE=$(printf '%s\n' "$POST_RESP" | tail -1)
POST_BODY=$(printf '%s\n' "$POST_RESP" | sed '$d')
[[ "$POST_CODE" == "202" ]] || fail "platform POST → $POST_CODE (expected 202): $POST_BODY"
EXEC_ID=$(printf '%s' "$POST_BODY" | jq -r '.execution_id // empty')
[[ -n "$EXEC_ID" ]] || fail "platform POST returned no execution_id: $POST_BODY"
ok "202 + execution_id=$EXEC_ID"

# ─── Step 2: poll PLATFORM until done (write region computes) ──────────────
section "2 — Poll platform until status=done"
P_START=$(date +%s)
P_STATUS=""
while (( $(date +%s) - P_START < PLATFORM_POLL_TIMEOUT_S )); do
    P_STATUS=$("${PLAT_CURL[@]}" "${BASE}/primes/${EXEC_ID}" | jq -r '.status // empty')
    [[ "$P_STATUS" == "done" ]] && break
    [[ "$P_STATUS" == "failed" ]] && fail "platform job failed"
    sleep 1
done
[[ "$P_STATUS" == "done" ]] || fail "platform did not reach done within ${PLATFORM_POLL_TIMEOUT_S}s (status=$P_STATUS)"
ok "platform status=done (result in platform bucket; DDB row replicating to peer)"

# ─── Step 3: cross-region poll on the PEER region ─────────────────────────
section "3 — Poll PEER region for the same execution_id (expect 503 recompute → 200)"
Q_START=$(date +%s)
SAW_503=0
PEER_RESULT=""
PEER_DONE=0
while (( $(date +%s) - Q_START < RETRY_BUDGET_S )); do
    Q_RESP=$("${PEER_CURL[@]}" -w '\n%{http_code}' "${BASE}/primes/${EXEC_ID}")
    Q_CODE=$(printf '%s\n' "$Q_RESP" | tail -1)
    Q_BODY=$(printf '%s\n' "$Q_RESP" | sed '$d')
    case "$Q_CODE" in
        503)
            SAW_503=1
            info "peer 503 — recompute-on-miss triggered (Retry-After advisory)"
            ;;
        200)
            Q_STATUS=$(printf '%s' "$Q_BODY" | jq -r '.status // empty')
            if [[ "$Q_STATUS" == "done" ]]; then
                if printf '%s' "$Q_BODY" | jq -e '.result != null' >/dev/null 2>&1; then
                    PEER_RESULT="$Q_BODY"
                    PEER_DONE=1
                    break
                fi
            elif [[ "$Q_STATUS" == "queued" || "$Q_STATUS" == "running" ]]; then
                info "peer status=$Q_STATUS — DDB row still replicating"
            elif [[ "$Q_STATUS" == "failed" ]]; then
                fail "peer reports job failed"
            fi
            ;;
        404)
            info "peer 404 — row not yet replicated"
            ;;
        *)
            warn "peer unexpected code $Q_CODE: $Q_BODY"
            ;;
    esac
    sleep "$POLL_INTERVAL_S"
done
ELAPSED=$(( $(date +%s) - Q_START ))
[[ "$PEER_DONE" == "1" ]] \
    || fail "peer did not serve a 200+done+result within ${RETRY_BUDGET_S}s (saw_503=$SAW_503)"
ok "peer served 200 + done + result in ${ELAPSED}s"

# ─── Step 4: verify the recomputed result is correct ──────────────────────
section "4 — Verify peer result against oracle count"
PEER_COUNT=$(printf '%s' "$PEER_RESULT" | jq -r '.result | length')
[[ "$PEER_COUNT" == "$EXPECTED_COUNT" ]] \
    || fail "peer result count=$PEER_COUNT, expected $EXPECTED_COUNT (range [$TEST_START,$TEST_END])"
ok "peer result count=$PEER_COUNT matches π-oracle"

# ─── Verdict ──────────────────────────────────────────────────────────────
section "Verdict"
if [[ "$SAW_503" == "1" ]]; then
    ok "ADR-0049 confirmed: peer returned 503 (recompute-on-miss) then served the regenerated result locally — no CRR."
else
    warn "Peer served the correct result, but NO 503 was observed. Either the
recompute completed between polls (lower POLL_INTERVAL_S to catch it), or the
object was already present in the peer bucket — which would mean replication
is still active. Investigate before trusting this as ADR-0049 evidence."
fi
ok "cross-region recompute-on-miss check PASSED"
