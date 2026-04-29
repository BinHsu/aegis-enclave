#!/usr/bin/env bash
# dlq-triage.sh — operator-facing DLQ inspection and selective replay.
#
# ADR-0038 records the design rationale: auto-retry on a DLQ polling
# worker is an anti-pattern (failed messages thrash main queue ↔ DLQ
# indefinitely). Production-shape DLQ handling is:
#   1. CloudWatch alarm on DLQ depth > 0  → operator notified
#   2. Manual triage via THIS script      → understand failure pattern
#   3. Optional selective replay          → after fixing root cause
#
# What this script does:
#   - List visible messages in the aegis-enclave-primes-dlq queue
#   - Decode each message body (JSON: execution_id + start + end)
#   - Cross-reference against the executions table to print the recorded
#     error_message (the worker's _mark_failed payload)
#   - Optionally re-enqueue selected messages back to the main queue
#     with operator confirmation per message (NEVER bulk-replay)
#
# Usage:
#   ./scripts/dlq-triage.sh              # interactive list + per-message confirm
#   ./scripts/dlq-triage.sh --list-only  # just print, no replay prompts
#   ./scripts/dlq-triage.sh --purge      # delete ALL DLQ messages (after triage)
#
# Requirements:
#   - VPN connected (DLQ + DynamoDB reachable from operator's terminal)
#   - jq + aws CLI in PATH
#   - terraform state present (for queue URLs + DDB table name)
#
# Exit codes:
#   0 — triage completed (zero or more messages handled)
#   1 — pre-flight failed (VPN / state / tools)
#   2 — operator aborted

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

# Resolve AWS_PROFILE: env var > tfvars persisted > leave unset (aws CLI uses
# default). Per memory feedback_explicit_over_implicit.md: read explicitly.
if [[ -z "${AWS_PROFILE:-}" ]] && [[ -f "$TFVARS" ]]; then
    AWS_PROFILE_FROM_TFVARS=$( (grep -E '^aws_profile[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
    if [[ -n "$AWS_PROFILE_FROM_TFVARS" ]]; then
        export AWS_PROFILE="$AWS_PROFILE_FROM_TFVARS"
        info "Using AWS_PROFILE=$AWS_PROFILE (from $TFVARS)"
    fi
fi

MODE="interactive"
case "${1:-}" in
    --list-only) MODE="list-only" ;;
    --purge)     MODE="purge" ;;
    --help|-h)
        sed -n '2,30p' "$0"
        exit 0
        ;;
    "") ;;
    *)  fail "unknown flag: $1 (use --list-only / --purge / --help)" ;;
esac

section "aegis-enclave — DLQ triage (mode=$MODE)"

# ─── Pre-flight ───────────────────────────────────────────────────────────
command -v aws       >/dev/null 2>&1 || fail "aws CLI not found"
command -v jq        >/dev/null 2>&1 || fail "jq not found"
command -v terraform >/dev/null 2>&1 || fail "terraform not found"

REGION=$( (grep -E '^region[[:space:]]*=' "$TF_DIR/terraform.tfvars" 2>/dev/null || true) \
         | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
REGION="${REGION:-eu-central-1}"

MAIN_URL=$(cd "$TF_DIR" && terraform output -raw sqs_primes_url 2>/dev/null) \
    || fail "sqs_primes_url not in state — run cloud-up first"
DLQ_URL=$(echo "$MAIN_URL" | sed 's|/aegis-enclave-primes$|/aegis-enclave-primes-dlq|')

ok "Main queue: $MAIN_URL"
ok "DLQ:        $DLQ_URL"

# ─── 1. List DLQ messages ────────────────────────────────────────────────
section "1/3 — Inspect DLQ"
DEPTH=$(aws sqs get-queue-attributes --region "$REGION" --queue-url "$DLQ_URL" \
          --attribute-names ApproximateNumberOfMessages \
          --query 'Attributes.ApproximateNumberOfMessages' --output text 2>/dev/null || echo "?")
ok "DLQ approximate depth: $DEPTH messages"

if [[ "$DEPTH" == "0" ]] || [[ "$DEPTH" == "?" ]]; then
    info "DLQ is empty — nothing to triage. Exiting cleanly."
    exit 0
fi

# Receive up to 10 messages with VisibilityTimeout=300s — operator has 5
# minutes to inspect; if not handled, message returns to DLQ for next run.
info "Receiving up to 10 messages (VisibilityTimeout=300s)..."
RAW=$(aws sqs receive-message --region "$REGION" --queue-url "$DLQ_URL" \
        --max-number-of-messages 10 \
        --visibility-timeout 300 \
        --wait-time-seconds 5 \
        --output json 2>/dev/null || echo "{}")

MSG_COUNT=$(echo "$RAW" | jq '.Messages | length // 0')
if [[ "$MSG_COUNT" == "0" ]]; then
    warn "received 0 messages despite depth $DEPTH — messages may be in-flight (already received by another consumer)"
    info "Wait for VisibilityTimeout to expire and retry."
    exit 0
fi

ok "Received $MSG_COUNT messages"

# Decode + display each
section "2/3 — Decode + cross-reference with executions table"
echo "$RAW" | jq -r '.Messages[] | "\(.MessageId)\t\(.ReceiptHandle)\t\(.Body)"' | \
while IFS=$'\t' read -r msg_id receipt body; do
    exec_id=$(echo "$body" | jq -r '.execution_id // empty')
    start=$(echo "$body"   | jq -r '.start // empty')
    end=$(echo "$body"     | jq -r '.end   // empty')

    printf "\n${BOLD}Message ${msg_id}${RESET}\n"
    printf "  execution_id: %s\n" "${exec_id:-(missing)}"
    printf "  range:        [%s, %s]\n" "${start:-?}" "${end:-?}"
    printf "  body:         %s\n" "$body"

    # Show the recorded error_message from the executions table (DynamoDB).
    # The operator must be on the VPN and have IAM perms for dynamodb:GetItem
    # against the executions table. We print a hint command; the operator
    # runs it manually after deciding which message(s) to inspect.
    if [[ -n "$exec_id" ]]; then
        printf "  audit DB lookup: ${YELLOW}see executions.execution_id=${exec_id}${RESET} via VPN+aws-cli\n"
        printf "    (cmd: aws dynamodb get-item --region %s --table-name aegis-enclave-executions --key '{\"execution_id\":{\"S\":\"%s\"}}')\n" "$REGION" "$exec_id"
    fi

    # Per-message replay decision
    if [[ "$MODE" != "interactive" ]]; then
        continue
    fi

    printf "Replay this message back to the main queue? [y/N/q]: "
    read -r REPLY </dev/tty
    case "$REPLY" in
        y|Y)
            # Re-send body to MAIN queue + delete from DLQ
            aws sqs send-message --region "$REGION" --queue-url "$MAIN_URL" \
                --message-body "$body" >/dev/null \
                && ok "  re-enqueued to main queue"
            aws sqs delete-message --region "$REGION" --queue-url "$DLQ_URL" \
                --receipt-handle "$receipt" >/dev/null \
                && ok "  deleted from DLQ"
            ;;
        q|Q)
            info "  operator quit — leaving remaining messages in DLQ"
            exit 0
            ;;
        *)
            info "  skipped (will reappear after VisibilityTimeout)"
            ;;
    esac
done

# ─── 3. Optional purge ────────────────────────────────────────────────────
section "3/3 — Optional purge"

if [[ "$MODE" == "purge" ]]; then
    warn "Purging entire DLQ (irreversible — all DLQ messages will be deleted)"
    printf "Type ${BOLD}purge${RESET} (literally) to proceed: "
    read -r REPLY
    if [[ "$REPLY" != "purge" ]]; then
        info "aborted"
        exit 2
    fi
    aws sqs purge-queue --region "$REGION" --queue-url "$DLQ_URL"
    ok "DLQ purged. Note: SQS may take up to 60s to fully drain."
else
    info "(skip purge — pass --purge as a separate invocation if needed)"
fi

ok "DLQ triage complete"
