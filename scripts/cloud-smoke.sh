#!/usr/bin/env bash
# cloud-smoke.sh — Phase 2.5 6-step smoke against the cloud-deployed prime service.
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
#   1. POST → assert 202 + execution_id
#   2. Poll GET until status=done (30s timeout)
#   3. Verify result length (25 primes in [2,100])
#   4. Repeat → measure cache-hit latency
#   5. Negative test: invalid range → 422
#   6. Backpressure: N concurrent large requests → some 503
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

ENDPOINT_HOST="${ENDPOINT_HOST:-api.enclave.internal}"
BACKPRESSURE_N="${BACKPRESSURE_N:-20}"
POLL_TIMEOUT="${POLL_TIMEOUT:-30}"

section "aegis-enclave — cloud smoke (Phase 2.5)"

# ─── Pre-flight: tools + state ────────────────────────────────────────────
section "0/6 — Pre-flight"
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH"
command -v jq        >/dev/null 2>&1 || fail "jq not found in PATH (brew install jq)"
command -v dig       >/dev/null 2>&1 || fail "dig not found in PATH"

ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name 2>/dev/null) \
    || fail "alb_dns_name output missing — run 'make cloud-up' first"
ok "alb_dns_name: $ALB_DNS"

ALB_IP=$(dig +short "$ALB_DNS" | grep -E '^[0-9.]+$' | head -1)
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
[[ "$HEALTH_CODE" == "200" ]] || fail "health probe returned $HEALTH_CODE — VPN may be disconnected
(timeout / 000 = network unreachable). Connect VPN and retry."
ok "GET /health → 200"

# ─── Step 1: POST → 202 + execution_id ────────────────────────────────────
section "1/6 — POST /primes (async accept)"
RESP=$("${CURL[@]}" -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
        -d '{"start":2,"end":100}' "${BASE}/primes")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
[[ "$HTTP_CODE" == "202" ]] || fail "expected 202, got $HTTP_CODE: $BODY"
EXEC_ID=$(echo "$BODY" | jq -r '.execution_id // empty')
[[ -n "$EXEC_ID" ]] || fail "no execution_id in response: $BODY"
ok "202 + execution_id=$EXEC_ID"

# ─── Step 2: Poll GET until status=done ───────────────────────────────────
section "2/6 — Poll until status=done (timeout ${POLL_TIMEOUT}s)"
STATUS=""
T_START=$(date +%s)
while (( $(date +%s) - T_START < POLL_TIMEOUT )); do
    STATUS=$("${CURL[@]}" "${BASE}/primes/${EXEC_ID}" | jq -r '.status // empty')
    [[ "$STATUS" == "done" ]] && break
    [[ "$STATUS" == "failed" ]] && {
        ERR=$("${CURL[@]}" "${BASE}/primes/${EXEC_ID}" | jq -r '.error_message // "unknown"')
        fail "execution failed: $ERR"
    }
    sleep 1
done
[[ "$STATUS" == "done" ]] || fail "polling timeout after ${POLL_TIMEOUT}s (last status=$STATUS)"
T_FIRST_MS=$(( ($(date +%s) - T_START) * 1000 ))
ok "polled to done in ${T_FIRST_MS}ms"

# ─── Step 3: Verify result length ─────────────────────────────────────────
section "3/6 — Verify primes count"
COUNT=$("${CURL[@]}" "${BASE}/primes/${EXEC_ID}" | jq -r '.result | length')
[[ "$COUNT" == "25" ]] || fail "expected 25 primes in [2,100], got $COUNT"
ok "primes count = 25 (correct for [2,100])"

# ─── Step 4: Cache-hit repeat ─────────────────────────────────────────────
section "4/6 — Cache hit (repeat same range, expect lower latency than first call)"
T2_START_MS=$(($(date +%s%N) / 1000000))
RESP2=$("${CURL[@]}" -X POST -H 'Content-Type: application/json' \
         -d '{"start":2,"end":100}' "${BASE}/primes")
EXEC_ID_2=$(echo "$RESP2" | jq -r '.execution_id // empty')
T2_HALF_MS=$(( $(date +%s%N) / 1000000 - T2_START_MS ))

# Poll second exec to done
T2_POLL_START=$(date +%s)
STATUS_2=""
while (( $(date +%s) - T2_POLL_START < POLL_TIMEOUT )); do
    STATUS_2=$("${CURL[@]}" "${BASE}/primes/${EXEC_ID_2}" | jq -r '.status // empty')
    [[ "$STATUS_2" == "done" ]] && break
    sleep 1
done
T2_TOTAL_MS=$(( ($(date +%s) - T2_POLL_START) * 1000 + T2_HALF_MS ))
[[ "$STATUS_2" == "done" ]] || fail "cache-hit second exec did not reach done"
ok "second call: ${T2_TOTAL_MS}ms total (vs first ${T_FIRST_MS}ms)"
if (( T2_TOTAL_MS < T_FIRST_MS )); then
    ok "cache hit: faster than miss ✓"
else
    warn "second call not faster — possible cache miss (worker fresh? Lua merge slow?)"
fi

# ─── Step 5: Negative test: out-of-bounds range → 422 ─────────────────────
section "5/6 — Negative test (out-of-bounds → 422)"
HTTP_CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -d '{"start":-1,"end":100}' "${BASE}/primes")
[[ "$HTTP_CODE" == "422" ]] || fail "expected 422 for negative start, got $HTTP_CODE"
ok "negative test: 422 ✓"

# ─── Step 6: Backpressure: N concurrent large → some 503 ──────────────────
section "6/6 — Backpressure (${BACKPRESSURE_N} concurrent, expect ≥ 1 × 503)"
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
ok "6/6 cloud smoke complete against $BASE"
echo "  First call (cache miss):  ${T_FIRST_MS}ms"
echo "  Second call (cache hit):  ${T2_TOTAL_MS}ms"
echo "  Backpressure 503 count:   ${HIT_503} / ${BACKPRESSURE_N}"
echo
info "Now run 'make cloud-evidence' to capture CloudWatch artifacts BEFORE 'make cloud-down'"
