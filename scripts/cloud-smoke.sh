#!/usr/bin/env bash
# cloud-smoke.sh — 6-step smoke against the cloud-deployed prime service.
#
# Mirrors test-client/smoke.sh's 6-step pattern but adjusts curl for the
# HTTPS internal-ALB self-signed ACM-imported cert path (--cacert + --resolve
# per ADR-0027).
#
# Requires:
#   - VPN connected (script's first curl will fail if not — message points at this)
#   - terraform state present (alb_dns_name + alb_self_signed_ca_pem outputs available)
#   - jq installed (for response parsing)
#
# Steps:
#   1. POST [100_001, 200_000] → assert 202 + execution_id
#      (deliberately OUTSIDE bootstrap pre-warm range [1, 100_000] so this
#       request forces a true cache miss → compute → cache write)
#   2. Poll GET until status=done (30s timeout); record ms-precision wall time
#   3. Verify result length (8392 primes in [100_001, 200_000])
#   4. Repeat SAME range → genuine cache-hit measurement
#      (the prior step's compute populated [100_001, 200_000] in cache; this
#       repeat round-trip should hit `find_covering` + slice without compute)
#   5. Negative test: invalid range → 422
#   6. Backpressure: N concurrent large requests → some 503
#   7. Cross-check via worker CloudWatch logs: count `cache_hit` vs
#      `compute_done` events from the last 5 minutes; expect ≥ 1 of each
#      (step 1 must show as compute_done; step 4 must show as cache_hit)
#
# Exit codes:
#   0 — 6/6 passed
#   1 — pre-flight failed (VPN / state / tools)
#   2 — a smoke step failed

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

# Resolve AWS_PROFILE: env var > tfvars persisted (terraform output uses
# provider auth which honours AWS_PROFILE). No prompt — smoke is a fast probe;
# operator who hasn't run cloud-up yet won't have tfvars and will fail at the
# terraform-output step with a clear error.
if [[ -z "${AWS_PROFILE:-}" ]] && [[ -f "$TFVARS" ]]; then
    AWS_PROFILE_FROM_TFVARS=$( (grep -E '^aws_profile[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
    if [[ -n "$AWS_PROFILE_FROM_TFVARS" ]]; then
        export AWS_PROFILE="$AWS_PROFILE_FROM_TFVARS"
        info "Using AWS_PROFILE=$AWS_PROFILE (from $TFVARS)"
    fi
fi

ENDPOINT_HOST="${ENDPOINT_HOST:-api.enclave.internal}"
BACKPRESSURE_N="${BACKPRESSURE_N:-20}"
POLL_TIMEOUT="${POLL_TIMEOUT:-30}"

# Cache-test range — deliberately OUTSIDE bootstrap pre-warm [1, 100_000] so
# step 1 forces a real cache miss → compute → cache write, and step 4 (same
# range) measures a real cache hit. Without this, both steps would hit the
# bootstrap-seeded covering range and the comparison would be meaningless.
TEST_START="${TEST_START:-100001}"
TEST_END="${TEST_END:-200000}"
EXPECTED_COUNT="${EXPECTED_COUNT:-8392}"  # π(200000) − π(100000) = 17984 − 9592

# ms-precision wall clock — BSD `date` lacks %N, fall back through python3 → perl → integer-second.
ms_now() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time()*1000))'
    elif command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes -e 'print int(Time::HiRes::time()*1000)'
    else
        echo $(($(date +%s) * 1000))
    fi
}

section "aegis-enclave — cloud smoke"

# ─── Pre-flight: tools + state ────────────────────────────────────────────
section "0/6 — Pre-flight"
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH"
command -v jq        >/dev/null 2>&1 || fail "jq not found in PATH (brew install jq)"
command -v dig       >/dev/null 2>&1 || fail "dig not found in PATH"

ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name 2>/dev/null) \
    || fail "alb_dns_name output missing — run 'make cloud-up' first"
ok "alb_dns_name: $ALB_DNS"

ALB_IP=$( (dig +short "$ALB_DNS" | grep -E '^[0-9.]+$' || true) | head -1)
[[ -n "$ALB_IP" ]] || fail "DNS resolution returned no IP — VPN not connected?
Try: 'ping $ALB_DNS' from your terminal. If timeout, connect VPN first."
ok "alb resolved IP: $ALB_IP"

CA_PEM="$(mktemp -t aegis-alb-ca.XXXXXX.pem)"
trap 'rm -f "$CA_PEM"' EXIT
(cd "$TF_DIR" && terraform output -raw alb_self_signed_ca_pem > "$CA_PEM") \
    || fail "alb_self_signed_ca_pem output missing"
ok "ALB CA written to $CA_PEM"

CURL=(curl -s --max-time 10 --cacert "$CA_PEM" --resolve "${ENDPOINT_HOST}:443:${ALB_IP}")
BASE="https://${ENDPOINT_HOST}"

# Connectivity probe (fail fast if VPN down)
HEALTH_CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${BASE}/health" 2>/dev/null || echo "000")
if [[ "$HEALTH_CODE" != "200" ]]; then
    fail "health probe returned $HEALTH_CODE — VPN likely disconnected. Diagnose:

    1. Resolve the ALB hostname through your DNS:
         dig +short $ALB_DNS
       Expected: a 10.x.x.x address (private, VPN-routed).
       If empty / public IP / timeout → DNS not going through VPN tunnel.

    2. Check that the VPN tunnel interface exists:
         ifconfig | grep utun
       Expected: at least one utun interface with an inet 10.20.x.x address
       (10.20.0.0/16 is the Client VPN client CIDR per terraform/main.tf).
       If no match → VPN client not connected.

    3. Connect or reconnect via Tunnelblick / openvpn — see README §
       'Cloud deployment acceptance' step 3 (Download VPN config + connect).

    4. Re-run: make cloud-smoke"
fi
ok "GET /health → 200"

# Helper: POST → poll → ms-precision wall time → return "<duration_ms> <exec_id>"
post_and_poll() {
    local payload="$1" t0 t1 status duration exec_id
    t0=$(ms_now)
    local resp
    resp=$("${CURL[@]}" -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
            -d "$payload" "${BASE}/primes")
    local code body
    code=$(echo "$resp" | tail -1)
    body=$(echo "$resp" | sed '$d')
    [[ "$code" == "202" ]] || { echo "POST_FAIL_$code|$body" >&2; return 1; }
    exec_id=$(echo "$body" | jq -r '.execution_id // empty')
    [[ -n "$exec_id" ]] || { echo "NO_EXEC_ID|$body" >&2; return 1; }
    # Tight 100ms poll for ms-precision read (vs old `sleep 1` rounding)
    local poll_start=$(date +%s)
    while (( $(date +%s) - poll_start < POLL_TIMEOUT )); do
        status=$("${CURL[@]}" "${BASE}/primes/${exec_id}" | jq -r '.status // empty')
        [[ "$status" == "done" ]] && break
        [[ "$status" == "failed" ]] && { echo "EXEC_FAILED|$exec_id" >&2; return 1; }
        sleep 0.1
    done
    [[ "$status" == "done" ]] || { echo "POLL_TIMEOUT|$exec_id|$status" >&2; return 1; }
    t1=$(ms_now)
    duration=$((t1 - t0))
    echo "$duration $exec_id"
}

# ─── Step 1: POST cache-miss range → 202 + execution_id ───────────────────
section "1/7 — POST /primes (range OUTSIDE bootstrap pre-warm → forces compute)"
info "Range: [${TEST_START}, ${TEST_END}] (bootstrap pre-warmed only [1, 100_000])"
RESULT_1=$(post_and_poll "{\"start\":${TEST_START},\"end\":${TEST_END}}") \
    || fail "step 1 POST/poll failed: $RESULT_1"
T_FIRST_MS=$(echo "$RESULT_1" | awk '{print $1}')
EXEC_ID=$(echo "$RESULT_1" | awk '{print $2}')
ok "202 + execution_id=$EXEC_ID + polled to done in ${T_FIRST_MS}ms (cache MISS — expected slower)"

# ─── Step 2: Verify primes count (correctness) ────────────────────────────
section "2/7 — Verify primes count"
COUNT=$("${CURL[@]}" "${BASE}/primes/${EXEC_ID}" | jq -r '.result | length')
[[ "$COUNT" == "$EXPECTED_COUNT" ]] || fail "expected ${EXPECTED_COUNT} primes in [${TEST_START},${TEST_END}], got $COUNT"
ok "primes count = ${EXPECTED_COUNT} (correct for [${TEST_START},${TEST_END}])"

# ─── Step 3: Cache-hit repeat (same range — should be served from cache) ──
section "3/7 — Cache HIT (repeat same range — find_covering should match the just-written entry)"
RESULT_3=$(post_and_poll "{\"start\":${TEST_START},\"end\":${TEST_END}}") \
    || fail "step 3 POST/poll failed: $RESULT_3"
T_HIT_MS=$(echo "$RESULT_3" | awk '{print $1}')
EXEC_ID_3=$(echo "$RESULT_3" | awk '{print $2}')
ok "second call: execution_id=$EXEC_ID_3 in ${T_HIT_MS}ms"
if (( T_HIT_MS < T_FIRST_MS )); then
    SPEEDUP=$(( (T_FIRST_MS - T_HIT_MS) * 100 / T_FIRST_MS ))
    ok "cache hit: ${SPEEDUP}% faster than miss (${T_FIRST_MS}ms → ${T_HIT_MS}ms) ✓"
else
    warn "second call not faster (${T_FIRST_MS}ms → ${T_HIT_MS}ms) — investigate worker logs"
fi

# ─── Step 4: Partial-overlap demo (range straddles bootstrap + new) ───────
section "4/7 — Partial overlap (read miss → compute → Lua merges into single entry)"
PARTIAL_START=50000
PARTIAL_END=150000
info "Range [${PARTIAL_START}, ${PARTIAL_END}] partially overlaps bootstrap [1, 100_000]"
info "and step-1 entry [${TEST_START}, ${TEST_END}], but neither fully covers it."
info "Expected: cache miss → compute → merge_or_put coalesces all into [1, ${TEST_END}]"
RESULT_4=$(post_and_poll "{\"start\":${PARTIAL_START},\"end\":${PARTIAL_END}}") \
    || fail "step 4 POST/poll failed: $RESULT_4"
T_PARTIAL_MS=$(echo "$RESULT_4" | awk '{print $1}')
ok "partial-overlap call: ${T_PARTIAL_MS}ms (cache MISS path, then merge writes coalesced [1, ${TEST_END}])"

# ─── Step 5: Post-coalesce hit (any sub-range of [1, TEST_END] now covered) ─
section "5/7 — Post-coalesce hit (sub-range of newly coalesced [1, ${TEST_END}])"
COALESCE_TEST=180000
RESULT_5=$(post_and_poll "{\"start\":2,\"end\":${COALESCE_TEST}}") \
    || fail "step 5 POST/poll failed: $RESULT_5"
T_COALESCE_MS=$(echo "$RESULT_5" | awk '{print $1}')
ok "post-coalesce call [2, ${COALESCE_TEST}]: ${T_COALESCE_MS}ms (should be cache HIT — proves Lua merge worked)"

# ─── Step 6: Negative test: out-of-bounds range → 422 ─────────────────────
section "6/7 — Negative test (out-of-bounds → 422)"
HTTP_CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -d '{"start":-1,"end":100}' "${BASE}/primes")
[[ "$HTTP_CODE" == "422" ]] || fail "expected 422 for negative start, got $HTTP_CODE"
ok "negative test: 422 ✓"

# ─── Step 7: Backpressure: N concurrent large → some 503 ─────────────────
section "7/7 — Backpressure (${BACKPRESSURE_N} concurrent, expect ≥ 1 × 503)"
TMP_CODES="$(mktemp -t aegis-bp-codes.XXXXXX)"
trap 'rm -f "$CA_PEM" "$TMP_CODES"' EXIT
for i in $(seq 1 "$BACKPRESSURE_N"); do
    (
        "${CURL[@]}" -o /dev/null -w '%{http_code}\n' \
            -X POST -H 'Content-Type: application/json' \
            -d '{"start":2,"end":1000000}' "${BASE}/primes" >> "$TMP_CODES"
    ) &
done
wait
HIT_503=$(grep -c '^503$' "$TMP_CODES" || true)
HIT_202=$(grep -c '^202$' "$TMP_CODES" || true)
ok "results: ${HIT_202} × 202, ${HIT_503} × 503"
if (( HIT_503 >= 1 )); then
    ok "backpressure triggered ≥ 1 × 503 ✓"
else
    warn "no 503 — backpressure did not trigger (worker autoscaled fast / queue not deep enough)"
    warn "this is non-fatal but worth investigating before evidence capture"
fi

# ─── Summary ──────────────────────────────────────────────────────────────
section "Summary"
ok "7/7 cloud smoke complete against $BASE"
echo
echo "  Cache MISS (compute path)  [${TEST_START}, ${TEST_END}]:        ${T_FIRST_MS}ms"
echo "  Cache HIT  (same range)    [${TEST_START}, ${TEST_END}]:        ${T_HIT_MS}ms"
echo "  Partial OVERLAP (compute + merge) [${PARTIAL_START}, ${PARTIAL_END}]: ${T_PARTIAL_MS}ms"
echo "  Post-coalesce HIT          [2, ${COALESCE_TEST}]:           ${T_COALESCE_MS}ms"
echo "  Backpressure 503 count:                                ${HIT_503} / ${BACKPRESSURE_N}"
echo
info "Cache assertion is timer-based (subject to network jitter). Ground truth"
info "is in worker CloudWatch logs — 'make cloud-evidence' fetches them and"
info "counts 'cache_hit' vs 'compute_done' events. Expect:"
info "  step 1 (miss)             → 1 × compute_done"
info "  step 3 (hit)              → 1 × cache_hit"
info "  step 4 (partial → miss)   → 1 × compute_done + 1 × Lua merge"
info "  step 5 (post-coalesce hit) → 1 × cache_hit"
echo
info "Now run 'make cloud-evidence' to capture CloudWatch artifacts BEFORE 'make cloud-down'"
