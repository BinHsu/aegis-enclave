#!/usr/bin/env bash
# ts_apply.sh — operator-facing Terraform apply wrapper for aegis-enclave.
#
# This script is the low-level apply wrapper used by:
#   - the case-study cloud-acceptance window (per ADR-0034 — bounded
#     apply-then-destroy with evidence capture; supersedes ADR-0015's
#     original plan-only stance for that window)
#   - operator production adoption (see docs/production_adoption.md)
#
# For the cloud-acceptance window, prefer `make cloud-up` (orchestrates this
# script plus VPN cert provisioning + ECR build/push). For surgical
# re-apply, call this script directly.
#
# Pre-flight checks performed before any AWS API call:
#   1. Bash + Terraform + AWS CLI installed
#   2. terraform/terraform.tfvars exists (not just the .example)
#   3. terraform.tfvars has no placeholder ARN values
#   4. AWS CLI is authenticated and points at the expected account/region
#   5. ACM certificates referenced by *_cert_arn variables actually exist
#   6. Terraform working directory is initialised
#
# After all checks pass:
#   - terraform plan -out=tfplan
#   - Display plan summary
#   - Prompt for confirmation (must type 'yes')
#   - terraform apply tfplan
#   - Display outputs
#
# Usage:
#   ./scripts/ts_apply.sh             # interactive, confirms before applying
#   ./scripts/ts_apply.sh --plan-only # plan only, no prompt or apply

set -euo pipefail

# ─── Colour output (degrades cleanly if NO_COLOR is set) ───────────────────
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    readonly RED=$'\033[31m'
    readonly GREEN=$'\033[32m'
    readonly YELLOW=$'\033[33m'
    readonly BLUE=$'\033[34m'
    readonly BOLD=$'\033[1m'
    readonly RESET=$'\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

ok()   { printf "${GREEN}\xe2\x9c\x93${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}\xe2\x9a\xa0${RESET} %s\n" "$*" >&2; }
fail() { printf "${RED}\xe2\x9c\x97${RESET} %s\n" "$*" >&2; exit 1; }
info() { printf "${BLUE}\xe2\x86\x92${RESET} %s\n" "$*"; }
section() { printf "\n${BOLD}── %s ──${RESET}\n" "$*"; }

# ─── Locate repo root + Terraform dir ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
TFVARS="$TF_DIR/terraform.tfvars"

PLAN_ONLY=0
if [[ "${1:-}" == "--plan-only" ]]; then
    PLAN_ONLY=1
fi

# ─── Banner ────────────────────────────────────────────────────────────────
section "aegis-enclave — Terraform apply wrapper"
echo "Repo:       $REPO_ROOT"
echo "Terraform:  $TF_DIR"
echo "tfvars:     $TFVARS"
[[ $PLAN_ONLY -eq 1 ]] && echo "Mode:       PLAN ONLY (no apply)"
echo
echo "${BOLD}Note:${RESET} Cloud-acceptance window apply (ADR-0034 supersedes ADR-0015 plan-only for this window)."
echo "      Bounded apply-then-destroy with evidence capture (see strategy notes for cost ceiling)."
echo "      Prefer 'make cloud-up' which orchestrates this script + cert + ECR + image push."

# ─── Tool presence ─────────────────────────────────────────────────────────
section "1/6 — Tool presence"
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH"
ok "terraform: $(terraform version | head -1)"
command -v aws >/dev/null 2>&1 || fail "aws CLI not found in PATH"
ok "aws CLI:   $(aws --version 2>&1 | head -1)"

# ─── tfvars presence ───────────────────────────────────────────────────────
section "2/6 — terraform.tfvars present"
if [[ ! -f "$TFVARS" ]]; then
    fail "terraform.tfvars missing.

      Copy from the example:
        cp terraform/terraform.tfvars.example terraform/terraform.tfvars

      Then edit the values per docs/production_adoption.md § 7."
fi
ok "$TFVARS exists"

# ─── Placeholder ARNs not present ─────────────────────────────────────────
section "3/6 — Placeholder ARNs replaced"
PLACEHOLDER_ACCOUNTS=$(grep -E 'arn:aws:acm:.*:000000000000:|arn:aws:acm:.*:111111111111:' "$TFVARS" || true)
if [[ -n "$PLACEHOLDER_ACCOUNTS" ]]; then
    fail "terraform.tfvars still contains placeholder ACM ARNs:

$PLACEHOLDER_ACCOUNTS

      Replace with real ACM cert ARNs per docs/production_adoption.md § 3."
fi
ok "no placeholder ARNs detected"

# ─── AWS authentication ────────────────────────────────────────────────────
section "4/6 — AWS authentication"
# Resolve AWS_PROFILE: env var > tfvars persisted. Per memory
# feedback_explicit_over_implicit.md: read explicitly, log source.
if [[ -z "${AWS_PROFILE:-}" ]] && [[ -f "$TFVARS" ]]; then
    AWS_PROFILE_FROM_TFVARS=$( (grep -E '^aws_profile[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
    if [[ -n "$AWS_PROFILE_FROM_TFVARS" ]]; then
        export AWS_PROFILE="$AWS_PROFILE_FROM_TFVARS"
        info "Using AWS_PROFILE=$AWS_PROFILE (from $TFVARS)"
    fi
fi
CALLER_JSON=$(aws sts get-caller-identity 2>&1) || fail "aws sts get-caller-identity failed:
$CALLER_JSON"
ACCOUNT_ID=$(echo "$CALLER_JSON" | grep -oE '"Account":[^,}]*' | sed -E 's/.*"([0-9]+)".*/\1/')
ARN=$(echo "$CALLER_JSON" | grep -oE '"Arn":[^,}]*' | sed -E 's/"Arn":[[:space:]]*"(.+)"/\1/')
ok "AWS account: $ACCOUNT_ID"
ok "AWS caller:  $ARN"

# ─── ACM certs exist ───────────────────────────────────────────────────────
# Reads from BOTH terraform.tfvars (operator-managed) and *.auto.tfvars
# (e.g. cert-arns.auto.tfvars written by cloud-up.sh). Defensive: '|| echo ""'
# avoids silent set -e + pipefail exit when grep finds no match.
section "5/6 — ACM certificates reachable"

# Helper: grep a var across all tfvars + auto.tfvars files in $TF_DIR
parse_tfvar() {
    local name="$1"
    local match=""
    for f in "$TF_DIR"/terraform.tfvars "$TF_DIR"/*.auto.tfvars; do
        [[ -f "$f" ]] || continue
        match=$(grep -E "^${name}[[:space:]]*=" "$f" 2>/dev/null | tail -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true)
        [[ -n "$match" ]] && { echo "$match"; return 0; }
    done
    return 1
}

REGION=$(parse_tfvar "region" || echo "")
SERVER_CERT=$(parse_tfvar "server_cert_arn" || echo "")
CLIENT_CERT=$(parse_tfvar "client_cert_arn" || echo "")

[[ -n "$REGION" ]] || fail "could not parse region from $TF_DIR/{terraform,*.auto}.tfvars"
[[ -n "$SERVER_CERT" ]] || fail "could not parse server_cert_arn from $TF_DIR/{terraform,*.auto}.tfvars (run 'make cloud-up' to bootstrap certs)"
[[ -n "$CLIENT_CERT" ]] || fail "could not parse client_cert_arn from $TF_DIR/{terraform,*.auto}.tfvars (run 'make cloud-up' to bootstrap certs)"

info "server_cert_arn=$SERVER_CERT"
info "client_cert_arn=$CLIENT_CERT"

ACM_RAW=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$SERVER_CERT" 2>&1) || {
    printf "\n--- aws acm describe-certificate (server) failed ---\n%s\n--- end ---\n" "$ACM_RAW" >&2
    fail "server_cert_arn not reachable in region $REGION. Check IAM perm acm:DescribeCertificate or ARN validity."
}
ok "server_cert_arn reachable"

ACM_RAW=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CLIENT_CERT" 2>&1) || {
    printf "\n--- aws acm describe-certificate (client) failed ---\n%s\n--- end ---\n" "$ACM_RAW" >&2
    fail "client_cert_arn not reachable in region $REGION."
}
ok "client_cert_arn reachable"

# ─── Terraform initialised ─────────────────────────────────────────────────
section "6/6 — Terraform initialised"
if [[ ! -d "$TF_DIR/.terraform" ]]; then
    info ".terraform/ missing — running terraform init"
    (cd "$TF_DIR" && terraform init)
fi
(cd "$TF_DIR" && terraform validate >/dev/null) || fail "terraform validate failed"
ok "terraform init + validate ok"

# ─── Plan ──────────────────────────────────────────────────────────────────
section "Plan"
PLAN_FILE="$TF_DIR/.tfplan-$(date -u +%Y%m%dT%H%M%SZ)"
trap '[[ -f "$PLAN_FILE" ]] && rm -f "$PLAN_FILE"' EXIT
(cd "$TF_DIR" && terraform plan -var-file=terraform.tfvars -out="$PLAN_FILE")
ok "plan written to $PLAN_FILE"

if [[ $PLAN_ONLY -eq 1 ]]; then
    info "PLAN ONLY mode — exiting without apply"
    rm -f "$PLAN_FILE"
    trap - EXIT
    exit 0
fi

# ─── Confirm ───────────────────────────────────────────────────────────────
section "Confirm apply"
echo "About to ${BOLD}terraform apply${RESET} against:"
echo "  AWS account: $ACCOUNT_ID"
echo "  Region:      $REGION"
echo "  Caller:      $ARN"
echo
printf "Type ${BOLD}yes${RESET} to proceed (anything else aborts): "
read -r REPLY
if [[ "$REPLY" != "yes" ]]; then
    info "aborted by operator"
    rm -f "$PLAN_FILE"
    trap - EXIT
    exit 1
fi

# ─── Apply ─────────────────────────────────────────────────────────────────
section "Apply"
(cd "$TF_DIR" && terraform apply "$PLAN_FILE")
rm -f "$PLAN_FILE"
trap - EXIT

# ─── Outputs ───────────────────────────────────────────────────────────────
section "Outputs"
(cd "$TF_DIR" && terraform output) || warn "no outputs declared — skipping"

ok "apply complete"
echo
info "Next steps:"
echo "  - Verify the smoke test against the deployed endpoint (README § Initial Acceptance)"
echo "  - Configure DNS / Route 53 to point at the internal ALB if needed"
echo "  - Distribute Client VPN client config to operators"
