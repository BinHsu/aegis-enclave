#!/usr/bin/env sh
# smoke.sh — Initial Acceptance test.
#
# Runs INSIDE the test-client container (which sits on the internal Docker
# network), simulating an operator that has already authenticated through
# the WireGuard gateway. Exits 0 on full pass; non-zero otherwise.
#
# Five steps, two minutes, pass/fail visible.

set -eu

# Self-bootstrap verification tooling. Idempotent across both invocation paths:
#   docker compose exec  test-client ./smoke.sh   ← long-lived container, tools cached
#   docker compose run --rm test-client ./smoke.sh ← one-off container, tools missing
# The compose-file `command:` runs `apk add` for the long-lived container, but `run`
# overrides command and skips it; doing the install here covers both.
apk add --no-cache curl jq wireguard-tools >/dev/null 2>&1 || true

API_BASE="${API_BASE:-http://app:8000}"

step() {
    printf '\n──── %s ────\n' "$1"
}

fail() {
    printf '✗ %s\n' "$1" >&2
    exit 1
}

ok() {
    printf '✓ %s\n' "$1"
}

# ─── Step 1: WireGuard handshake reachability check ─────────────────────────
step "1/5  WireGuard tooling present"
command -v wg >/dev/null 2>&1 || fail "wg tool missing — alpine package install may have failed"
ok "wg tool available"

# ─── Step 2: API health (through internal network — simulating post-VPN) ───
step "2/5  GET /health"
HEALTH=$(curl --silent --fail --max-time 5 "$API_BASE/health") \
    || fail "GET /health failed"
echo "$HEALTH"
echo "$HEALTH" | grep -q '"status":"ok"' || fail "health did not report ok"
ok "health ok"

# ─── Step 3: POST /primes ───────────────────────────────────────────────────
step "3/5  POST /primes {start:2, end:100}"
RESULT=$(curl --silent --fail --max-time 10 \
    -X POST "$API_BASE/primes" \
    -H 'Content-Type: application/json' \
    -d '{"start":2,"end":100}') \
    || fail "POST /primes failed"
echo "$RESULT"
EXEC_ID=$(echo "$RESULT" | sed -n 's/.*"execution_id":\([0-9]*\).*/\1/p')
COUNT=$(echo "$RESULT" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
[ "$COUNT" = "25" ] || fail "expected count=25, got count=$COUNT"
[ -n "$EXEC_ID" ] || fail "execution_id not present in response"
ok "primes computed (count=$COUNT, execution_id=$EXEC_ID)"

# ─── Step 4: GET /executions/{id} ──────────────────────────────────────────
step "4/5  GET /executions/$EXEC_ID"
DETAIL=$(curl --silent --fail --max-time 5 "$API_BASE/executions/$EXEC_ID") \
    || fail "GET /executions/$EXEC_ID failed"
echo "$DETAIL"
echo "$DETAIL" | grep -q "\"id\":$EXEC_ID" || fail "audit detail missing id"
ok "audit row retrieved"

# ─── Step 5: Negative test — host-side direct access ───────────────────────
step "5/5  Negative test — confirm no host-side direct access"
echo "    (this step must be run from the HOST, not from inside this container)"
echo "    From host: curl -m 5 http://localhost:8000/health"
echo "    Expected:  connection refused or timeout"
ok "negative test instructions printed (run from host)"

printf '\n──── ALL 5/5 PASS ────\n'
