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

# The region we apply against (the default-provider / platform region). Used in
# the confirm-apply summary below. ADR-0042: it is `platform_region`, not a
# top-level `region`.
REGION=$( ( grep -E '^platform_region[[:space:]]*=' "$TF_DIR"/terraform.tfvars 2>/dev/null || true ) | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' )
[[ -n "$REGION" ]] || fail "could not parse platform_region from $TF_DIR/terraform.tfvars"

# Verify every ACM certificate referenced in the tfvars is reachable before
# the apply (fail-fast). ADR-0042: the server/client cert ARNs are nested
# inside the per-region `regions` map (indented; one pair per region), and
# each ARN encodes its own region — so collect them all and check each in the
# region from its ARN, rather than parsing a single top-level `region`.
CERT_ARNS=$(
    for f in "$TF_DIR"/terraform.tfvars "$TF_DIR"/*.auto.tfvars; do
        [[ -f "$f" ]] || continue
        ( grep -E "^[[:space:]]*(server|client)_cert_arn[[:space:]]*=" "$f" 2>/dev/null || true ) \
            | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/'
    done | sort -u
)
[[ -n "$CERT_ARNS" ]] \
    || fail "no server_cert_arn / client_cert_arn found in $TF_DIR/{terraform,*.auto}.tfvars (run 'make cloud-up' to bootstrap certs)"

CERT_COUNT=0
while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    case "$arn" in
        PENDING:*) fail "cert ARN still a sentinel ($arn) — VPN PKI bootstrap incomplete; run 'make cloud-up'" ;;
        arn:aws:acm:*) : ;;
        *) fail "unrecognised cert ARN format: $arn" ;;
    esac
    cert_region=$(printf '%s' "$arn" | cut -d: -f4)
    [[ -n "$cert_region" ]] || fail "could not derive region from cert ARN: $arn"
    ACM_RAW=$(aws acm describe-certificate --region "$cert_region" --certificate-arn "$arn" 2>&1) || {
        printf "\n--- aws acm describe-certificate failed (%s) ---\n%s\n--- end ---\n" "$arn" "$ACM_RAW" >&2
        fail "cert not reachable: $arn (region $cert_region). Check acm:DescribeCertificate perm or ARN validity."
    }
    ok "cert reachable: ${arn##*/} ($cert_region)"
    CERT_COUNT=$((CERT_COUNT + 1))
done <<EOF
$CERT_ARNS
EOF
ok "$CERT_COUNT ACM certificate(s) reachable across regions"

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
