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
#   TF_ALB_HOSTNAME, TF_WORKER_MIN, TF_WORKER_MAX, TF_ALARM_EMAIL
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
PROFILES_AVAIL=$(aws configure list-profiles 2>/dev/null || true)
SSO_SESSIONS_AVAIL=$(grep -E '^\[sso-session ' ~/.aws/config 2>/dev/null | sed 's/^\[sso-session \(.*\)\]/\1/' || true)

if [[ -z "${AWS_PROFILE:-}" ]]; then
    if (( IS_BATCH )); then
        fail "AWS_PROFILE not set (batch mode requires explicit AWS_PROFILE env var)"
    fi
    if [[ -n "$PROFILES_AVAIL" ]]; then
        printf "Available AWS profiles:\n"
        echo "$PROFILES_AVAIL" | sed 's/^/  - /'
    fi
    if [[ -n "$SSO_SESSIONS_AVAIL" ]]; then
        printf "SSO sessions (for reference, not pickable as profile):\n"
        echo "$SSO_SESSIONS_AVAIL" | sed 's/^/  - /'
    fi
    printf "Enter AWS_PROFILE [default]: "
    read -r AWS_PROFILE_INPUT
    export AWS_PROFILE="${AWS_PROFILE_INPUT:-default}"
fi
info "Using AWS_PROFILE=$AWS_PROFILE"

if [[ -n "$PROFILES_AVAIL" ]] && ! echo "$PROFILES_AVAIL" | grep -qx "$AWS_PROFILE"; then
    printf "\nProfile '%s' is NOT in 'aws configure list-profiles'. Available:\n" "$AWS_PROFILE" >&2
    echo "$PROFILES_AVAIL" | sed 's/^/  - /' >&2
    fail "Re-run and pick from the list above"
fi

AUTH_RAW=""
AUTH_RC=0
AUTH_RAW=$(aws sts get-caller-identity 2>&1) || AUTH_RC=$?

if [[ "$AUTH_RC" -ne 0 ]]; then
    printf "\n--- aws sts get-caller-identity --profile %s failed (exit %d) ---\n%s\n--- end ---\n" \
        "$AWS_PROFILE" "$AUTH_RC" "$AUTH_RAW" >&2

    if ! aws configure list-profiles 2>/dev/null | grep -qx "$AWS_PROFILE"; then
        printf "\nProfile '%s' is NOT in 'aws configure list-profiles'. Available:\n" "$AWS_PROFILE" >&2
        aws configure list-profiles 2>/dev/null | sed 's/^/  - /' >&2
        printf "\nSSO sessions in your config:\n" >&2
        (grep -E '^\[sso-session ' ~/.aws/config 2>/dev/null | sed 's/^\[sso-session \(.*\)\]/  - \1/' || echo "  (none)") >&2
        fail "Profile '$AWS_PROFILE' does not exist"
    fi

    if (( IS_BATCH )); then
        if [[ -n "${SSO_SESSION:-}" ]]; then
            info "Refreshing SSO (SSO_SESSION=$SSO_SESSION env var, batch mode)"
            aws sso login --sso-session "$SSO_SESSION" || fail "SSO login failed"
        else
            fail "AWS auth failed (batch mode — cannot prompt). Set SSO_SESSION env var or refresh creds before retrying."
        fi
    else
        printf "SSO session name to refresh token (Enter to skip): "
        read -r SSO_SESSION_INPUT
        if [[ -n "$SSO_SESSION_INPUT" ]]; then
            info "Running: aws sso login --sso-session $SSO_SESSION_INPUT"
            aws sso login --sso-session "$SSO_SESSION_INPUT" || fail "SSO login failed"
        fi
    fi

    AUTH_RC=0
    AUTH_RAW=$(aws sts get-caller-identity 2>&1) || AUTH_RC=$?
    if [[ "$AUTH_RC" -ne 0 ]]; then
        printf "\n--- aws sts STILL fails (exit %d) ---\n%s\n--- end ---\n" "$AUTH_RC" "$AUTH_RAW" >&2
        fail "AWS auth still failing"
    fi
fi

ACCOUNT_ID=$( ( printf '%s' "$AUTH_RAW" | grep -oE '"Account":[[:space:]]*"[0-9]+"' | grep -oE '[0-9]+' | head -1 ) 2>/dev/null || echo "?" )
ok "AWS account: $ACCOUNT_ID"

# ─── Helpers ───────────────────────────────────────────────────────────────
ask() {
    # Three-tier resolution (per memory feedback_interactive_scripts_must_have_batch_mode.md):
    #   1. env var TF_<UPPER_VAR_NAME> set → use it, log source
    #   2. batch mode → use default, log source
    #   3. interactive → prompt with default
    # Note: tr-based uppercase for bash 3.2 compatibility (macOS default bash;
    #       ${var^^} is bash 4+ only).
    local var_name="$1" prompt_msg="$2" default="$3"
    local env_var="TF_$(echo "$var_name" | tr '[:lower:]' '[:upper:]')"
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
    local upper="$(echo "$var_name" | tr '[:lower:]' '[:upper:]')"
    if (( IS_BATCH )); then
        fail "TF_${upper}='$var_value' invalid: $reason (batch mode — aborting)"
    fi
    warn "$reason"
    return 0
}

validate_region() {
    # Returns 0 if region exists/enabled; 1 if not found; 2 if API call failed.
    local region="$1" raw rc=0
    raw=$(aws ec2 describe-regions --region us-east-1 \
            --query "Regions[?RegionName=='$region'].RegionName" --output text 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf "\n--- aws ec2 describe-regions failed (exit %d) ---\n%s\n--- end ---\n" \
            "$rc" "$raw" >&2
        if echo "$raw" | grep -qE 'UnauthorizedOperation|AccessDenied'; then
            printf "Hint: looks like missing IAM permission ec2:DescribeRegions.\n" >&2
        fi
        return 2
    fi
    echo "$raw" | grep -q "^$region$"
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
        printf "\n--- aws ec2 describe-vpcs --region %s failed (exit %d) ---\n%s\n--- end ---\n" \
            "$region" "$rc" "$raw" >&2
        if echo "$raw" | grep -qE 'UnauthorizedOperation|AccessDenied'; then
            printf "Hint: looks like missing IAM permission ec2:DescribeVpcs.\n" >&2
        fi
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

validate_email_or_empty() {
    # Empty string is valid (means: skip SNS notifications). Non-empty must
    # look like an email address (matches terraform/variables.tf validation).
    [[ -z "$1" ]] || [[ "$1" =~ ^[^@]+@[^@]+\.[^@]+$ ]]
}

# ─── Q&A: region (validated) ───────────────────────────────────────────────
section "Region"
while true; do
    ask REGION "AWS region" "eu-central-1"
    set +e
    validate_region "$REGION"
    rc=$?
    set -e
    case $rc in
        0) ok "region '$REGION' enabled in account $ACCOUNT_ID"; break ;;
        1) batch_fail_or_retry REGION "$REGION" \
               "region '$REGION' not in 'aws ec2 describe-regions' (not enabled / typo)" ;;
        2) fail "Cannot validate region — API call failed. See stderr above for missing IAM permission.
For batch / CI: grant ec2:DescribeRegions to the runner role." ;;
    esac
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
               fail "Cannot validate CIDR — describe-vpcs API failed. See stderr above for missing IAM permission.
For batch / CI: grant ec2:DescribeVpcs to the runner role.
(CI without AWS access must not run tfvars-init / cloud-up — see Bin 04/26 rule.)"
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
    ask WORKER_MIN "Worker min count (ECS desired_count floor; 3 = one task per AZ in 3-AZ posture)" "3"
    if validate_positive_int "$WORKER_MIN"; then break; fi
    batch_fail_or_retry WORKER_MIN "$WORKER_MIN" "must be non-negative integer"
done
while true; do
    ask WORKER_MAX "Worker max count (autoscale ceiling; 9 keeps 3x scale headroom over min=3)" "9"
    if validate_positive_int "$WORKER_MAX" && [[ "$WORKER_MAX" -ge "$WORKER_MIN" ]]; then
        break
    fi
    batch_fail_or_retry WORKER_MAX "$WORKER_MAX" "must be integer ≥ worker_min_count ($WORKER_MIN)"
done

# ─── Q&A: SNS alarm email (optional; opt-in delivery per ADR-0041) ─────────
section "Alarm email (optional)"
info "If set, terraform creates an SNS topic + email subscription. Alarms still"
info "fire to EventBridge audit trail regardless. AWS will email a confirmation"
info "link to the address on first apply — the operator must click it before"
info "alarm notifications deliver."
while true; do
    ask ALARM_EMAIL "Email for alarm notifications (Enter to skip)" ""
    if validate_email_or_empty "$ALARM_EMAIL"; then
        if [[ -z "$ALARM_EMAIL" ]]; then
            ok "alarm_email empty — alarms will fire silently (EventBridge audit trail only)"
        else
            ok "alarm_email = $ALARM_EMAIL"
        fi
        break
    fi
    batch_fail_or_retry ALARM_EMAIL "$ALARM_EMAIL" "not a valid email address (or leave empty to skip)"
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
alarm_email           = "$ALARM_EMAIL"

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
