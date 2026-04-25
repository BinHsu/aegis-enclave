#!/usr/bin/env bash
# ts_apply.sh — operator-facing Terraform apply wrapper for aegis-enclave.
#
# This script is for OPERATOR PRODUCTION ADOPTION (see docs/production_adoption.md),
# NOT for case-study operation. ADR-0015 explicitly defers `terraform apply` for
# the case-study cycle — the deliverable is plan-only. Run this script only when
# you have decided to adopt the composition into a real AWS environment.
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
echo "${BOLD}Note:${RESET} This script is for operator adoption (docs/production_adoption.md)."
echo "      The case-study cycle itself is plan-only per ADR-0015 — do NOT run this"
echo "      in production without first reviewing the plan output."

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
CALLER_JSON=$(aws sts get-caller-identity 2>&1) || fail "aws sts get-caller-identity failed:
$CALLER_JSON"
ACCOUNT_ID=$(echo "$CALLER_JSON" | grep -oE '"Account":[^,}]*' | sed -E 's/.*"([0-9]+)".*/\1/')
ARN=$(echo "$CALLER_JSON" | grep -oE '"Arn":[^,}]*' | sed -E 's/"Arn":[[:space:]]*"(.+)"/\1/')
ok "AWS account: $ACCOUNT_ID"
ok "AWS caller:  $ARN"

# ─── ACM certs exist ───────────────────────────────────────────────────────
section "5/6 — ACM certificates reachable"
REGION=$(grep -E '^region[[:space:]]*=' "$TFVARS" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
SERVER_CERT=$(grep -E '^server_cert_arn[[:space:]]*=' "$TFVARS" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
CLIENT_CERT=$(grep -E '^client_cert_arn[[:space:]]*=' "$TFVARS" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')

[[ -n "$REGION" ]] || fail "could not parse region from $TFVARS"
[[ -n "$SERVER_CERT" ]] || fail "could not parse server_cert_arn from $TFVARS"
[[ -n "$CLIENT_CERT" ]] || fail "could not parse client_cert_arn from $TFVARS"

aws acm describe-certificate --region "$REGION" --certificate-arn "$SERVER_CERT" >/dev/null 2>&1 \
    || fail "server_cert_arn not reachable: $SERVER_CERT
      Verify the cert exists in region $REGION and the caller has acm:DescribeCertificate."
ok "server_cert_arn reachable"

aws acm describe-certificate --region "$REGION" --certificate-arn "$CLIENT_CERT" >/dev/null 2>&1 \
    || fail "client_cert_arn not reachable: $CLIENT_CERT"
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
