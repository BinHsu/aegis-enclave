#!/usr/bin/env bash
# tfvars-init.sh — terraform.tfvars generator with AWS-aware validation.
#
# Two modes:
#   - Interactive (default if stdin is a TTY): prompts for each var with
#     default in brackets; press Enter to accept, type to override.
#   - Batch / non-interactive (auto if no TTY, or --batch flag): no prompts;
#     each var sourced from env var TF_<UPPER_NAME> if set, else default.
#     Validation failures are FATAL (no retry).
#
# AWS-aware checks (require valid AWS_PROFILE + creds):
#   - region:  must be in `aws ec2 describe-regions` (enabled in account)
#   - vpc_cidr: must NOT overlap any existing VPC CIDR in account+region
#               (describe-vpcs CidrBlockAssociationSet). API failure → accept
#               with warning in batch mode; yes/no prompt in interactive.
#
# Sanity-only checks (no AWS call):
#   - vpc_cidr format: valid IPv4 network notation (python3 ipaddress)
#   - alb_internal_hostname: valid RFC 1123 hostname
#   - worker_min/max_count: positive integer; max ≥ min
#
# Idempotent: if terraform.tfvars exists, exits 0 with "skipping" message.
# Pass --force to re-prompt / regenerate.
#
# Usage — interactive:
#   make tfvars-init                       # standalone
#   ./scripts/tfvars-init.sh --force       # overwrite existing
#   AWS_PROFILE=corp make tfvars-init      # explicit profile
#
# Usage — CI / batch (env var override per prompt; convention TF_<UPPER>):
#   TF_REGION=eu-west-1 \
#   TF_OWNER=ci-runner \
#   TF_VPC_CIDR=10.10.0.0/16 \
#   TF_WORKER_MAX=5 \
#   ./scripts/tfvars-init.sh --batch
#
# Env vars supported (uppercase prefix TF_, override prompt + default):
#   TF_REGION, TF_ENVIRONMENT, TF_COST_CENTER, TF_OWNER, TF_VPC_CIDR,
#   TF_ALB_HOSTNAME, TF_WORKER_MIN, TF_WORKER_MAX
#
# Called automatically by cloud-up.sh when terraform.tfvars is missing.

set -euo pipefail

# ─── Colour ────────────────────────────────────────────────────────────────
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

FORCE=0
IS_BATCH=0
[[ -t 0 ]] || IS_BATCH=1   # no stdin TTY → auto batch
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --batch) IS_BATCH=1 ;;
        --help|-h) sed -n '/^# Usage/,/^# Called/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    esac
done

section "aegis-enclave — tfvars-init ($([ $IS_BATCH -eq 1 ] && echo batch || echo interactive))"

# ─── Idempotent guard ──────────────────────────────────────────────────────
if [[ -f "$TFVARS" && "$FORCE" != "1" ]]; then
    info "$TFVARS already exists — skipping (pass --force to re-prompt)"
    exit 0
fi

# ─── AWS auth (source-agnostic; SSO recommended) ───────────────────────────
section "AWS auth (for region + CIDR validation)"
if [[ -z "${AWS_PROFILE:-}" ]]; then
    if (( IS_BATCH )); then
        fail "AWS_PROFILE not set (batch mode requires explicit AWS_PROFILE env var)"
    fi
    printf "AWS_PROFILE not set. Enter profile name [default]: "
    read -r AWS_PROFILE_INPUT
    export AWS_PROFILE="${AWS_PROFILE_INPUT:-default}"
fi
info "Using AWS_PROFILE=$AWS_PROFILE"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    if (( IS_BATCH )); then
        # Batch mode: don't try interactive sso login (would block on browser)
        fail "AWS auth failed for profile '$AWS_PROFILE' (batch mode — cannot run 'aws sso login' interactively).
Refresh creds in the calling environment before running --batch:
  aws sso login --profile $AWS_PROFILE
or set AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (CI runner pattern)."
    fi
    if aws configure get sso_session --profile "$AWS_PROFILE" >/dev/null 2>&1 \
       || aws configure get sso_start_url --profile "$AWS_PROFILE" >/dev/null 2>&1; then
        info "profile is SSO-configured — running 'aws sso login --profile $AWS_PROFILE'"
        aws sso login --profile "$AWS_PROFILE" || fail "SSO login failed"
    else
        fail "AWS auth failed for profile '$AWS_PROFILE'.
Recommended: 'aws configure sso --profile $AWS_PROFILE' (SSO is the recommended path).
Or: check ~/.aws/credentials for valid long-term keys."
    fi
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ok "AWS account: $ACCOUNT_ID"

# ─── Helpers ───────────────────────────────────────────────────────────────
ask() {
    # Three-tier resolution (per memory feedback_interactive_scripts_must_have_batch_mode.md):
    #   1. env var TF_<UPPER_VAR_NAME> set → use it, log source
    #   2. batch mode → use default, log source
    #   3. interactive → prompt with default
    local var_name="$1" prompt_msg="$2" default="$3"
    local env_var="TF_${var_name^^}"
    local env_value="${!env_var:-}"

    if [[ -n "$env_value" ]]; then
        eval "$var_name=\"\$env_value\""
        ok "$var_name = $env_value (from \$$env_var)"
        return 0
    fi
    if (( IS_BATCH )); then
        eval "$var_name=\"\$default\""
        info "$var_name = $default (batch default; override with \$$env_var)"
        return 0
    fi
    printf "%s [%s]: " "$prompt_msg" "$default"
    read -r value
    eval "$var_name=\"\${value:-\$default}\""
}

# Helper for validation loops: in batch mode, fail-fast on invalid input
# (no infinite re-prompt). In interactive mode, return 0 = retry.
batch_fail_or_retry() {
    local var_name="$1" var_value="$2" reason="$3"
    if (( IS_BATCH )); then
        fail "TF_${var_name^^}='$var_value' invalid: $reason (batch mode — aborting)"
    fi
    warn "$reason"
    return 0
}

validate_region() {
    aws ec2 describe-regions --region us-east-1 \
        --query "Regions[?RegionName=='$1'].RegionName" --output text 2>/dev/null \
        | grep -q "^$1$"
}

validate_cidr_format() {
    python3 -c "import ipaddress; ipaddress.ip_network('$1', strict=False)" 2>/dev/null
}

check_cidr_overlap() {
    # Exit codes:
    #   0 — no overlap (safe to use)
    #   1 — overlaps existing CIDR (must retry)
    #   2 — API call failed (cannot validate; caller decides whether to abort or accept)
    local proposed="$1" region="$2"
    local raw rc=0
    raw=$(aws ec2 describe-vpcs --region "$region" \
            --query 'Vpcs[*].CidrBlockAssociationSet[*].CidrBlock' --output text 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf "describe-vpcs failed: %s\n" "$raw" >&2
        return 2
    fi
    local existing
    existing=$(echo "$raw" | tr '\t' '\n' | grep -v '^$' || true)
    if [[ -z "$existing" ]]; then
        return 0   # no existing VPCs in this region — trivially no overlap
    fi
    python3 - "$proposed" "$existing" <<'PYEOF'
import sys, ipaddress
proposed = ipaddress.ip_network(sys.argv[1], strict=False)
existing = sys.argv[2].split()
overlaps = [c for c in existing if proposed.overlaps(ipaddress.ip_network(c, strict=False))]
if overlaps:
    print(f"overlaps existing VPC CIDR(s): {', '.join(overlaps)}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

validate_hostname() {
    # RFC 1123: labels are [a-z0-9]([-a-z0-9]*[a-z0-9])?, max 63 chars per label
    [[ "$1" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?)*$ ]]
}

validate_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 0 ]]
}

# ─── Q&A: region (validated) ───────────────────────────────────────────────
section "Region"
while true; do
    ask REGION "AWS region" "eu-central-1"
    if validate_region "$REGION"; then
        ok "region '$REGION' enabled in account $ACCOUNT_ID"
        break
    fi
    batch_fail_or_retry REGION "$REGION" \
        "region '$REGION' not in 'aws ec2 describe-regions' (not enabled / typo)"
done

# ─── Q&A: tags (free text) ─────────────────────────────────────────────────
section "Tags"
ask ENVIRONMENT "Environment tag" "case-study"
ask COST_CENTER "Cost center tag" "engineering"
ask OWNER "Owner tag (your name / handle / DL)" "$(whoami)"

# ─── Q&A: VPC CIDR (validated for format + no overlap) ─────────────────────
section "Network"
while true; do
    ask VPC_CIDR "VPC CIDR" "10.0.0.0/16"
    if ! validate_cidr_format "$VPC_CIDR"; then
        batch_fail_or_retry VPC_CIDR "$VPC_CIDR" "not a valid IPv4 network notation"
        continue
    fi
    info "checking overlap against existing VPCs in $REGION..."
    set +e
    check_cidr_overlap "$VPC_CIDR" "$REGION"
    rc=$?
    set -e
    case $rc in
        0) ok "no CIDR overlap in $REGION"; break ;;
        1) batch_fail_or_retry VPC_CIDR "$VPC_CIDR" \
               "overlaps existing VPC CIDR in $REGION (try 10.10.0.0/16 / 172.20.0.0/16 / 192.168.100.0/24)" ;;
        2) # AWS API failure. CI without AWS access should NOT run cloud-up — fail in batch.
           if (( IS_BATCH )); then
               fail "describe-vpcs API failed (batch mode). CI without AWS access must not run tfvars-init / cloud-up.
Provision AWS access for the runner (IAM role / OIDC / explicit creds) before retrying."
           fi
           warn "AWS API failed — cannot auto-validate CIDR. Accept anyway? [yes/no]"
           read -r ack
           if [[ "$ack" == "yes" ]]; then
               ok "accepted '$VPC_CIDR' without API validation"
               break
           else
               warn "re-prompting CIDR"
           fi ;;
    esac
done

# ─── Q&A: ALB internal hostname (format validated) ─────────────────────────
section "ALB"
while true; do
    ask ALB_HOSTNAME "Internal ALB hostname (operator's curl --resolve target)" "api.enclave.internal"
    if validate_hostname "$ALB_HOSTNAME"; then
        ok "valid hostname"
        break
    fi
    batch_fail_or_retry ALB_HOSTNAME "$ALB_HOSTNAME" "not a valid RFC 1123 hostname"
done

# ─── Q&A: worker counts (validated integers) ───────────────────────────────
section "Worker autoscale"
while true; do
    ask WORKER_MIN "Worker min count (ECS desired_count floor)" "1"
    if validate_positive_int "$WORKER_MIN"; then break; fi
    batch_fail_or_retry WORKER_MIN "$WORKER_MIN" "must be non-negative integer"
done
while true; do
    ask WORKER_MAX "Worker max count (autoscale ceiling)" "3"
    if validate_positive_int "$WORKER_MAX" && [[ "$WORKER_MAX" -ge "$WORKER_MIN" ]]; then
        break
    fi
    batch_fail_or_retry WORKER_MAX "$WORKER_MAX" "must be integer ≥ worker_min_count ($WORKER_MIN)"
done

# ─── Write tfvars ──────────────────────────────────────────────────────────
section "Writing $TFVARS"
cat > "$TFVARS" <<EOF
# Auto-generated by scripts/tfvars-init.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Edit freely; this file is gitignored. Cert ARNs are written separately to
# cert-arns.auto.tfvars by scripts/cloud-up.sh.

region                = "$REGION"
environment           = "$ENVIRONMENT"
cost_center           = "$COST_CENTER"
owner                 = "$OWNER"
vpc_cidr              = "$VPC_CIDR"
alb_internal_hostname = "$ALB_HOSTNAME"
worker_min_count      = $WORKER_MIN
worker_max_count      = $WORKER_MAX

# ─── Less-commonly-tuned knobs (uncomment + edit if needed) ─────────────
# compute_budget_seconds         = 60        # SIGALRM worker timeout (ADR-0033)
# backpressure_threshold_factor  = 5         # 503 trigger: queue_depth > N × workers
# sqs_visibility_timeout         = 90        # = 1.5 × compute_budget (ADR-0033)
# valkey_max_storage_gb          = 1         # Valkey serverless storage cap (ADR-0031)
# valkey_max_ecpu_per_sec        = 5000      # Valkey serverless eCPU cap (ADR-0031)
EOF

ok "wrote $TFVARS"
echo
info "Next: run 'make cloud-up' (will skip tfvars step now that it exists)."
