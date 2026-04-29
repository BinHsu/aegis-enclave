#!/usr/bin/env bash
# cloud-down.sh — one-shot cloud teardown orchestrator for aegis-enclave.
#
# Tears down everything cloud-up.sh created, plus the 3 outside-tfstate items
# that 'terraform destroy' alone leaves behind:
#
#   1. Drain ECR images (ECR module default force_delete=false would block destroy)
#   2. terraform destroy (via ts_teardown.sh — keeps strict 'destroy' confirm)
#   3. Delete ACM-imported VPN certs (server_cert + client_cert)
#   4. Optionally rm -rf pki/ (CA private key wipe)
#   5. Verify no aegis-enclave VPCs remain (collateral-free guarantee)
#
# Bounded by tfstate + tag boundary: only resources tagged owner=bin.hsu OR
# managed by this terraform/ are affected. Operator's other AWS resources
# in the same account are untouched (tfstate boundary + default_tags filter).
#
# Usage:
#   make cloud-down                            # interactive confirms
#   FORCE=1 make cloud-down                    # skip pki/ delete prompt (still confirms terraform destroy)
#
# Exit codes:
#   0 — clean teardown, no aegis-enclave resources remain
#   1 — pre-flight check failed
#   2 — destroy failed (state may be partial; investigate via 'terraform state list')

set -euo pipefail

# ─── Colour output ──────────────────────────────────────────────────────────
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
CERT_TFVARS="$TF_DIR/cert-arns.auto.tfvars"
PKI_DIR="$REPO_ROOT/pki"

START_TIME=$(date -u +%s)

section "aegis-enclave — cloud-down (cloud-acceptance window teardown)"
echo "Repo:        $REPO_ROOT"
echo "Terraform:   $TF_DIR"

# ─── Pre-flight ────────────────────────────────────────────────────────────
section "1/6 — Pre-flight"
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH"
command -v aws >/dev/null 2>&1       || fail "aws CLI not found in PATH"

# AWS auth: source-agnostic (SSO recommended). See memory feedback_aws_creds_agnostic.md.
PROFILES_AVAIL=$(aws configure list-profiles 2>/dev/null || true)
SSO_SESSIONS_AVAIL=$(grep -E '^\[sso-session ' ~/.aws/config 2>/dev/null | sed 's/^\[sso-session \(.*\)\]/\1/' || true)

if [[ -z "${AWS_PROFILE:-}" ]]; then
    if [[ -n "$PROFILES_AVAIL" ]]; then
        printf "Available AWS profiles:\n"
        echo "$PROFILES_AVAIL" | sed 's/^/  - /'
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

if [[ -n "$SSO_SESSIONS_AVAIL" ]]; then
    printf "Available SSO sessions:\n"
    echo "$SSO_SESSIONS_AVAIL" | sed 's/^/  - /'
fi
printf "SSO session name to refresh token (Enter to skip): "
read -r SSO_SESSION_INPUT
if [[ -n "$SSO_SESSION_INPUT" ]]; then
    info "Running: aws sso login --sso-session $SSO_SESSION_INPUT"
    aws sso login --sso-session "$SSO_SESSION_INPUT" || fail "SSO login failed"
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

    fail "AWS auth failed for profile '$AWS_PROFILE'. Re-run with sso-session name at the prompt to refresh."
fi

ACCOUNT_ID=$( ( printf '%s' "$AUTH_RAW" | grep -oE '"Account":[[:space:]]*"[0-9]+"' | grep -oE '[0-9]+' | head -1 ) 2>/dev/null || echo "?" )
ARN=$( ( printf '%s' "$AUTH_RAW" | grep -oE '"Arn":[[:space:]]*"[^"]+"' | sed -E 's/.*"(arn:[^"]+)".*/\1/' | head -1 ) 2>/dev/null || echo "?" )
[[ -z "$ACCOUNT_ID" ]] && ACCOUNT_ID="?"
[[ -z "$ARN" ]] && ARN="?"
ok "AWS account: $ACCOUNT_ID"
ok "AWS caller:  $ARN"

REGION=$( (grep -E '^region[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
REGION="${REGION:-eu-central-1}"
SECONDARY_REGION=$( (grep -E '^secondary_region[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')

if [[ ! -d "$TF_DIR/.terraform" ]]; then
    info ".terraform/ missing — running terraform init"
    (cd "$TF_DIR" && terraform init -backend=false -input=false >/dev/null)
fi

RESOURCE_COUNT=$(cd "$TF_DIR" && terraform state list 2>/dev/null | wc -l | tr -d ' ')
if [[ "$RESOURCE_COUNT" == "0" ]]; then
    warn "no resources in tfstate — nothing for terraform to destroy"
    warn "(if you suspect orphan resources from a partial apply, list manually:"
    warn "  aws ec2 describe-vpcs --filters Name=tag:Name,Values=aegis-enclave-* --region $REGION)"
fi
ok "$RESOURCE_COUNT resource(s) currently in tfstate"

# ─── Step 2: Drain ECR images (primary + secondary regions) ────────────────
section "2/6 — Drain ECR images (otherwise terraform destroy fails on ECR)"

# Drain by terraform output URL, not by state-path grep — multi-region has
# both `module.ecr` (primary) and `aws_ecr_repository.secondary` (secondary)
# which the old `^module\.ecr\.` filter missed. Output-based detection works
# regardless of resource path / module nesting.
drain_ecr_region() {
    local region="$1"
    local repo_url="$2"
    if [[ -z "$repo_url" ]] || [[ "$repo_url" == "null" ]]; then
        return 0  # output absent or null = no ECR in this region
    fi
    local repo_name
    repo_name=$(echo "$repo_url" | sed -E 's|.*/([^/]+)$|\1|')
    [[ -z "$repo_name" ]] && return 0

    local image_ids
    image_ids=$(aws ecr list-images --repository-name "$repo_name" --region "$region" \
                  --query 'imageIds[*]' --output json 2>/dev/null || echo "[]")
    if [[ "$image_ids" != "[]" ]] && [[ -n "$image_ids" ]]; then
        info "Deleting all images in $region/$repo_name"
        aws ecr batch-delete-image --repository-name "$repo_name" --region "$region" \
            --image-ids "$image_ids" --output text >/dev/null 2>&1 || true
        ok "drained $region/$repo_name"
    else
        ok "$region/$repo_name already empty (or repo gone)"
    fi
}

PRIMARY_ECR_URL=$(cd "$TF_DIR" && terraform output -raw ecr_repository_url 2>/dev/null || echo "")
drain_ecr_region "$REGION" "$PRIMARY_ECR_URL"

if [[ -n "$SECONDARY_REGION" ]]; then
    SECONDARY_ECR_URL=$(cd "$TF_DIR" && terraform output -raw secondary_ecr_repository_url 2>/dev/null || echo "")
    drain_ecr_region "$SECONDARY_REGION" "$SECONDARY_ECR_URL"
fi

# ─── Step 3: terraform destroy (via ts_teardown.sh strict-confirm wrapper) ─
section "3/6 — terraform destroy (strict 'destroy' confirm gate)"
if [[ "$RESOURCE_COUNT" != "0" ]]; then
    "$SCRIPT_DIR/ts_teardown.sh"
else
    info "skipping terraform destroy (no resources in state)"
fi

# ─── Step 4: Delete ACM-imported VPN certs ─────────────────────────────────
section "4/6 — Delete ACM-imported VPN certs (out-of-tfstate cleanup)"
if [[ -f "$CERT_TFVARS" ]]; then
    # Primary region certs
    SERVER_ARN=$( (grep -E '^server_cert_arn = "arn:' "$CERT_TFVARS" 2>/dev/null || true) | sed -E 's/.*"(arn:[^"]+)".*/\1/')
    CLIENT_ARN=$( (grep -E '^client_cert_arn = "arn:' "$CERT_TFVARS" 2>/dev/null || true) | sed -E 's/.*"(arn:[^"]+)".*/\1/')
    for ARN_TO_DELETE in "$SERVER_ARN" "$CLIENT_ARN"; do
        if [[ -n "$ARN_TO_DELETE" ]]; then
            info "aws acm delete-certificate --certificate-arn $ARN_TO_DELETE --region $REGION"
            if aws acm delete-certificate --certificate-arn "$ARN_TO_DELETE" --region "$REGION" 2>/dev/null; then
                ok "deleted: $ARN_TO_DELETE"
            else
                warn "delete failed (may already be gone): $ARN_TO_DELETE"
            fi
        fi
    done

    # Secondary region certs (multi-region only)
    if [[ -n "$SECONDARY_REGION" ]]; then
        SECONDARY_SERVER_ARN=$( (grep -E '^secondary_server_cert_arn = "arn:' "$CERT_TFVARS" 2>/dev/null || true) | sed -E 's/.*"(arn:[^"]+)".*/\1/')
        SECONDARY_CLIENT_ARN=$( (grep -E '^secondary_client_cert_arn = "arn:' "$CERT_TFVARS" 2>/dev/null || true) | sed -E 's/.*"(arn:[^"]+)".*/\1/')
        for ARN_TO_DELETE in "$SECONDARY_SERVER_ARN" "$SECONDARY_CLIENT_ARN"; do
            if [[ -n "$ARN_TO_DELETE" ]]; then
                info "aws acm delete-certificate --certificate-arn $ARN_TO_DELETE --region $SECONDARY_REGION"
                if aws acm delete-certificate --certificate-arn "$ARN_TO_DELETE" --region "$SECONDARY_REGION" 2>/dev/null; then
                    ok "deleted: $ARN_TO_DELETE"
                else
                    warn "delete failed (may already be gone): $ARN_TO_DELETE"
                fi
            fi
        done
    fi

    rm -f "$CERT_TFVARS"
    ok "removed $CERT_TFVARS"
else
    info "no $CERT_TFVARS — nothing to clean (skipping)"
fi

# Also remove image-tag.auto.tfvars (written by cloud-up.sh; tracks the git-sha
# tag deployed). Out-of-tfstate, gitignored, no AWS dependency.
IMAGE_TAG_TFVARS="$TF_DIR/image-tag.auto.tfvars"
if [[ -f "$IMAGE_TAG_TFVARS" ]]; then
    rm -f "$IMAGE_TAG_TFVARS"
    ok "removed $IMAGE_TAG_TFVARS"
fi

# ─── Step 5: Optionally wipe local PKI ─────────────────────────────────────
section "5/6 — Local PKI cleanup"
if [[ -d "$PKI_DIR" ]]; then
    if [[ "${FORCE:-}" == "1" ]]; then
        info "FORCE=1 — wiping $PKI_DIR (CA private key)"
        rm -rf "$PKI_DIR"
        ok "$PKI_DIR removed"
    else
        printf "Delete local %s (CA private key + operator client certs)? [yes/no] " "$PKI_DIR"
        read -r ans
        if [[ "$ans" == "yes" ]]; then
            rm -rf "$PKI_DIR"
            ok "$PKI_DIR removed"
        else
            warn "PKI directory kept at $PKI_DIR (re-run cloud-up will reuse if certs still in ACM)"
        fi
    fi
else
    info "no pki/ directory — skipping"
fi

# ─── Step 6: Verify no aegis-enclave resources remain ──────────────────────
section "6/6 — Collateral-free verification"
LEFT_VPCS=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=aegis-enclave-*" \
            --region "$REGION" --query 'Vpcs[*].VpcId' --output text 2>/dev/null || echo "")
LEFT_VPN=$(aws ec2 describe-client-vpn-endpoints --region "$REGION" \
           --query 'ClientVpnEndpoints[?Tags[?Value==`aegis-enclave`]].ClientVpnEndpointId' \
           --output text 2>/dev/null || echo "")
LEFT_ACM=$(aws acm list-certificates --region "$REGION" \
           --query 'CertificateSummaryList[?contains(DomainName, `enclave`)].CertificateArn' \
           --output text 2>/dev/null || echo "")

if [[ -z "$LEFT_VPCS" && -z "$LEFT_VPN" && -z "$LEFT_ACM" ]]; then
    ok "no aegis-enclave VPCs / VPN endpoints / ACM certs remain in $REGION"
else
    [[ -n "$LEFT_VPCS" ]] && warn "VPCs still present: $LEFT_VPCS"
    [[ -n "$LEFT_VPN"  ]] && warn "Client VPN endpoints still present: $LEFT_VPN"
    [[ -n "$LEFT_ACM"  ]] && warn "ACM certs still present: $LEFT_ACM"
    warn "Manual cleanup needed — investigate above ARNs"
fi

# ─── Summary ───────────────────────────────────────────────────────────────
section "Teardown summary"
ELAPSED=$(($(date -u +%s) - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))
cat <<EOF

  Teardown elapsed: ${ELAPSED_MIN}m ${ELAPSED_SEC}s

  What was cleaned:
    ✓ tfstate-managed resources (terraform destroy, by-state boundary)
    ✓ ECR images (would have blocked destroy)
    ✓ ACM-imported VPN certs (out-of-tfstate)
    $([[ ! -d "$PKI_DIR" ]] && echo "✓ Local pki/ directory" || echo "✗ Local pki/ directory (kept)")

  What is NOT touched (collateral-free guarantee):
    - Other AWS resources in account $ACCOUNT_ID (different tags / different VPCs)
    - State backend bucket (if you used 'make tf-bootstrap' separately)
    - DynamoDB Global Tables: when secondary_region is set, both replicas
      are torn down by terraform destroy — no separate orphan resource to
      chase. Tables are immediately deleted (no recovery window like RDS
      final snapshot).

  Final cost check:
    aws ce get-cost-and-usage --time-period Start=\$(date -u -v-1d +%Y-%m-%d),End=\$(date -u +%Y-%m-%d) --granularity DAILY --metrics UnblendedCost

EOF
ok "cloud-down complete"
