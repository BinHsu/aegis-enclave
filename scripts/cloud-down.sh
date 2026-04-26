#!/usr/bin/env bash
# cloud-down.sh — one-shot cloud teardown orchestrator for aegis-enclave Phase 2.5.
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

section "aegis-enclave — cloud-down (Phase 2.5 teardown)"
echo "Repo:        $REPO_ROOT"
echo "Terraform:   $TF_DIR"

# ─── Pre-flight ────────────────────────────────────────────────────────────
section "1/6 — Pre-flight"
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH"
command -v aws >/dev/null 2>&1       || fail "aws CLI not found in PATH"

# AWS auth: source-agnostic (SSO recommended). See memory feedback_aws_creds_agnostic.md.
if [[ -z "${AWS_PROFILE:-}" ]]; then
    printf "AWS_PROFILE not set. Enter profile name [default]: "
    read AWS_PROFILE_INPUT
    export AWS_PROFILE="${AWS_PROFILE_INPUT:-default}"
fi
info "Using AWS_PROFILE=$AWS_PROFILE"

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

    printf "SSO session name to refresh token (Enter to skip): "
    read -r SSO_SESSION_INPUT
    if [[ -n "$SSO_SESSION_INPUT" ]]; then
        info "Running: aws sso login --sso-session $SSO_SESSION_INPUT"
        aws sso login --sso-session "$SSO_SESSION_INPUT" || fail "SSO login failed"
    fi

    AUTH_RC=0
    AUTH_RAW=$(aws sts get-caller-identity 2>&1) || AUTH_RC=$?
    if [[ "$AUTH_RC" -ne 0 ]]; then
        printf "\n--- aws sts STILL fails (exit %d) ---\n%s\n--- end ---\n" "$AUTH_RC" "$AUTH_RAW" >&2
        fail "AWS auth still failing"
    fi
fi

ACCOUNT_ID=$( ( printf '%s' "$AUTH_RAW" | grep -oE '"Account":[[:space:]]*"[0-9]+"' | grep -oE '[0-9]+' | head -1 ) 2>/dev/null || echo "?" )
ARN=$( ( printf '%s' "$AUTH_RAW" | grep -oE '"Arn":[[:space:]]*"[^"]+"' | sed -E 's/.*"(arn:[^"]+)".*/\1/' | head -1 ) 2>/dev/null || echo "?" )
[[ -z "$ACCOUNT_ID" ]] && ACCOUNT_ID="?"
[[ -z "$ARN" ]] && ARN="?"
ok "AWS account: $ACCOUNT_ID"
ok "AWS caller:  $ARN"

REGION=$(grep -E '^region[[:space:]]*=' "$TFVARS" 2>/dev/null | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
REGION="${REGION:-eu-central-1}"

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

# ─── Step 2: Drain ECR images ──────────────────────────────────────────────
section "2/6 — Drain ECR images (otherwise terraform destroy fails on ECR)"
if (cd "$TF_DIR" && terraform state list 2>/dev/null | grep -q '^module\.ecr\.'); then
    ECR_NAME=$(cd "$TF_DIR" && terraform output -raw ecr_repository_url 2>/dev/null | sed -E 's|.*/([^/]+)$|\1|')
    if [[ -n "$ECR_NAME" ]]; then
        IMAGE_IDS=$(aws ecr list-images --repository-name "$ECR_NAME" --region "$REGION" \
                    --query 'imageIds[*]' --output json 2>/dev/null || echo "[]")
        if [[ "$IMAGE_IDS" != "[]" && -n "$IMAGE_IDS" ]]; then
            info "Deleting all images in $ECR_NAME"
            aws ecr batch-delete-image --repository-name "$ECR_NAME" --region "$REGION" \
                --image-ids "$IMAGE_IDS" --output text >/dev/null
            ok "ECR images drained"
        else
            ok "ECR repository $ECR_NAME already empty"
        fi
    fi
else
    info "module.ecr not in state — skipping ECR drain"
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
    SERVER_ARN=$(grep -oE 'server_cert_arn[[:space:]]*=[[:space:]]*"arn:[^"]+"' "$CERT_TFVARS" | sed -E 's/.*"(arn:[^"]+)"/\1/')
    CLIENT_ARN=$(grep -oE 'client_cert_arn[[:space:]]*=[[:space:]]*"arn:[^"]+"' "$CERT_TFVARS" | sed -E 's/.*"(arn:[^"]+)"/\1/')
    for ARN_TO_DELETE in "$SERVER_ARN" "$CLIENT_ARN"; do
        if [[ -n "$ARN_TO_DELETE" ]]; then
            info "aws acm delete-certificate --certificate-arn $ARN_TO_DELETE"
            if aws acm delete-certificate --certificate-arn "$ARN_TO_DELETE" --region "$REGION" 2>/dev/null; then
                ok "deleted: $ARN_TO_DELETE"
            else
                warn "delete failed (may already be gone): $ARN_TO_DELETE"
            fi
        fi
    done
    rm -f "$CERT_TFVARS"
    ok "removed $CERT_TFVARS"
else
    info "no $CERT_TFVARS — nothing to clean (skipping)"
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
    - Secrets Manager: RDS master password is on a 7-day deletion window per
      RDS default; check 'aws secretsmanager list-secrets' if you want to
      force-delete the scheduled-deletion entry sooner.

  Final cost check:
    aws ce get-cost-and-usage --time-period Start=\$(date -u -v-1d +%Y-%m-%d),End=\$(date -u +%Y-%m-%d) --granularity DAILY --metrics UnblendedCost

EOF
ok "cloud-down complete"
