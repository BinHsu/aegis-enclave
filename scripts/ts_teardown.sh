#!/usr/bin/env bash
# ts_teardown.sh — operator-facing Terraform destroy wrapper for aegis-enclave.
#
# Tears down the AWS infrastructure provisioned by `ts_apply.sh`.
# Same pre-flight checks as apply, plus a stricter confirmation gate
# (operator must type the literal word 'destroy', not just 'y' or 'yes').
#
# This script is for OPERATOR PRODUCTION ADOPTION (see docs/production_adoption.md),
# NOT for case-study operation. ADR-0015 explicitly defers `terraform apply` /
# `terraform destroy` for the case-study cycle — there is no real state to
# tear down during the case-study deliverable.
#
# Usage:
#   ./scripts/ts_teardown.sh
#
# Exits cleanly (0) if no resources are in state — nothing to destroy.

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

# ─── Banner ────────────────────────────────────────────────────────────────
section "aegis-enclave — Terraform DESTROY wrapper"
echo "Repo:       $REPO_ROOT"
echo "Terraform:  $TF_DIR"
echo "tfvars:     $TFVARS"
echo
echo "${RED}${BOLD}WARNING:${RESET} This will destroy ALL infrastructure provisioned by terraform/."
echo "         Includes RDS database (data loss), ECS service, ALB, VPC + endpoints,"
echo "         Client VPN endpoint, ECR repository (and all images stored)."

# ─── Pre-flight: tools ─────────────────────────────────────────────────────
section "1/5 — Tool presence"
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH"
command -v aws >/dev/null 2>&1 || fail "aws CLI not found in PATH"
ok "tools present"

# ─── Pre-flight: tfvars ────────────────────────────────────────────────────
section "2/5 — tfvars present"
if [[ ! -f "$TFVARS" ]]; then
    fail "terraform.tfvars missing — cannot destroy without knowing what was applied."
fi
ok "$TFVARS present"

# ─── Pre-flight: AWS authentication ────────────────────────────────────────
section "3/5 — AWS authentication"
CALLER_JSON=$(aws sts get-caller-identity 2>&1) || fail "aws sts get-caller-identity failed:
$CALLER_JSON"
ACCOUNT_ID=$(echo "$CALLER_JSON" | grep -oE '"Account":[^,}]*' | sed -E 's/.*"([0-9]+)".*/\1/')
ARN=$(echo "$CALLER_JSON" | grep -oE '"Arn":[^,}]*' | sed -E 's/"Arn":[[:space:]]*"(.+)"/\1/')
ok "AWS account: $ACCOUNT_ID"
ok "AWS caller:  $ARN"

# ─── Pre-flight: state present ─────────────────────────────────────────────
section "4/5 — Terraform state present"
if [[ ! -d "$TF_DIR/.terraform" ]]; then
    info ".terraform/ missing — running terraform init"
    (cd "$TF_DIR" && terraform init)
fi
(cd "$TF_DIR" && terraform validate >/dev/null) || fail "terraform validate failed"

RESOURCE_COUNT=$(cd "$TF_DIR" && terraform state list 2>/dev/null | wc -l | tr -d ' ')
if [[ "$RESOURCE_COUNT" == "0" ]]; then
    info "no resources in state — nothing to destroy. Exiting cleanly."
    exit 0
fi
ok "$RESOURCE_COUNT resource(s) in state"

# ─── Plan -destroy ────────────────────────────────────────────────────────
section "5/5 — Plan destroy"
PLAN_FILE="$TF_DIR/.tfplan-destroy-$(date -u +%Y%m%dT%H%M%SZ)"
trap '[[ -f "$PLAN_FILE" ]] && rm -f "$PLAN_FILE"' EXIT
(cd "$TF_DIR" && terraform plan -destroy -var-file=terraform.tfvars -out="$PLAN_FILE")

# ─── Confirm — strict ─────────────────────────────────────────────────────
section "Confirm destroy"
REGION=$(grep -E '^region[[:space:]]*=' "$TFVARS" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
echo "About to ${RED}${BOLD}DESTROY${RESET} infrastructure in:"
echo "  AWS account: $ACCOUNT_ID"
echo "  Region:      ${REGION:-<not parsed>}"
echo "  Caller:      $ARN"
echo
echo "${RED}This is IRREVERSIBLE.${RESET} RDS data WILL BE LOST unless a final snapshot was"
echo "configured (the case-study composition has skip_final_snapshot = true)."
echo
printf "Type ${BOLD}destroy${RESET} (literally) to proceed: "
read -r REPLY
if [[ "$REPLY" != "destroy" ]]; then
    info "aborted by operator"
    rm -f "$PLAN_FILE"
    trap - EXIT
    exit 1
fi

# ─── Apply destroy ─────────────────────────────────────────────────────────
section "Destroy"
(cd "$TF_DIR" && terraform apply "$PLAN_FILE")
rm -f "$PLAN_FILE"
trap - EXIT

ok "destroy complete"
info "Note: ECR images and CloudWatch logs may still exist outside Terraform state."
info "      Verify and clean up manually if required."
