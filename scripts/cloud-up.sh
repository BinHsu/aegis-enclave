#!/usr/bin/env bash
# cloud-up.sh — one-shot cloud deployment orchestrator for aegis-enclave Phase 2.5.
#
# Sequences the operator's deploy workflow into a single command:
#   1. Pre-flight: AWS auth + docker daemon + terraform + tfvars present
#   2. VPN PKI provisioning (idempotent — skip if cert-arns.auto.tfvars valid)
#   3. ECR-target apply + image build + push (chicken-and-egg break)
#   4. Full terraform apply (Phase 2.5 cloud-acceptance window starts here)
#   5. Print operator next-steps (VPN config, ALB DNS, smoke command)
#
# Designed for the bounded apply-then-destroy window (≤ 3h, < $2 per ADR-0031
# 3h-window cost framing). Pair with `make cloud-down` for collateral-free teardown.
#
# Usage:
#   make cloud-up                              # uses OPERATOR=$(whoami)
#   OPERATOR=alice make cloud-up               # explicit operator name
#   AWS_REGION=eu-west-1 make cloud-up         # override default region
#
# Exit codes:
#   0 — cloud is up and reachable via VPN
#   1 — pre-flight check failed
#   2 — provisioning failed mid-flow (state may be partial; run cloud-down to clean)

set -euo pipefail

# ─── Colour output (degrades cleanly if NO_COLOR or non-TTY) ───────────────
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

# ─── Locate repo + Terraform dir ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
TFVARS="$TF_DIR/terraform.tfvars"
CERT_TFVARS="$TF_DIR/cert-arns.auto.tfvars"

OPERATOR="${OPERATOR:-$(whoami)}"
START_TIME=$(date -u +%s)

section "aegis-enclave — cloud-up (Phase 2.5 acceptance window)"
echo "Operator:    $OPERATOR"
echo "Repo:        $REPO_ROOT"
echo "Terraform:   $TF_DIR"

# ─── Pre-flight: tools ─────────────────────────────────────────────────────
section "1/6 — Tool presence"
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH"
command -v aws >/dev/null 2>&1       || fail "aws CLI not found in PATH"
command -v docker >/dev/null 2>&1    || fail "docker not found in PATH"
docker info >/dev/null 2>&1          || fail "docker daemon not running (start Docker Desktop?)"
ok "terraform / aws / docker all present and ready"

# ─── Pre-flight: AWS authentication (source-agnostic; SSO recommended) ────
# We don't care if the profile is SSO-configured or uses long-term creds —
# we only care that 'aws sts get-caller-identity' works. SSO is recommended
# (refreshable, short-lived tokens, audit trail) but long-term creds also work.
# See memory feedback_aws_creds_agnostic.md.
section "2/6 — AWS authentication"
if [[ -z "${AWS_PROFILE:-}" ]]; then
    printf "AWS_PROFILE not set. Enter profile name [default]: "
    read AWS_PROFILE_INPUT
    export AWS_PROFILE="${AWS_PROFILE_INPUT:-default}"
fi
info "Using AWS_PROFILE=$AWS_PROFILE"

# Verify creds; auto-trigger SSO login on expired token (no-op for long-term creds)
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    if aws configure get sso_session --profile "$AWS_PROFILE" >/dev/null 2>&1 \
       || aws configure get sso_start_url --profile "$AWS_PROFILE" >/dev/null 2>&1; then
        info "profile is SSO-configured (recommended) — running 'aws sso login --profile $AWS_PROFILE'"
        aws sso login --profile "$AWS_PROFILE" || fail "SSO login failed for profile $AWS_PROFILE"
    else
        fail "Long-term creds invalid/missing for profile '$AWS_PROFILE'.
Recommended fix: configure SSO via 'aws configure sso --profile $AWS_PROFILE'.
Or: check ~/.aws/credentials for valid long-term access keys."
    fi
fi

CALLER_JSON=$(aws sts get-caller-identity 2>&1) || fail "aws sts get-caller-identity still failed after auth attempt"
ACCOUNT_ID=$(echo "$CALLER_JSON" | grep -oE '"Account":[^,}]*' | sed -E 's/.*"([0-9]+)".*/\1/')
ARN=$(echo "$CALLER_JSON" | grep -oE '"Arn":"[^"]*"' | sed -E 's/"Arn":"(.+)"/\1/')
ok "AWS account: $ACCOUNT_ID"
ok "AWS caller:  $ARN"

# ─── Pre-flight: tfvars present ────────────────────────────────────────────
section "3/6 — tfvars present"
if [[ ! -f "$TFVARS" ]]; then
    info "$TFVARS missing — copying from terraform.tfvars.example"
    cp "$TF_DIR/terraform.tfvars.example" "$TFVARS"
    warn "tfvars created with defaults (region=eu-central-1, cost_center=engineering, owner=bin.hsu)"
    warn "If you want non-defaults, abort now (Ctrl-C) and edit $TFVARS"
    sleep 3
fi
ok "$TFVARS present"

REGION=$(grep -E '^region[[:space:]]*=' "$TFVARS" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
REGION="${REGION:-eu-central-1}"
ok "Region: $REGION"

# ─── Phase 1: VPN PKI provisioning (idempotent) ────────────────────────────
section "4/6 — VPN PKI + ACM import"
if [[ -f "$CERT_TFVARS" ]] && grep -q '^server_cert_arn = "arn:' "$CERT_TFVARS" \
                          && grep -q '^client_cert_arn = "arn:' "$CERT_TFVARS"; then
    ok "$CERT_TFVARS already has valid ARNs — skipping cert bootstrap"
else
    info "Running bootstrap-vpn-certs.sh --operator $OPERATOR --region $REGION"
    PKI_LOG="$REPO_ROOT/.cloud-up-pki-output.log"
    "$SCRIPT_DIR/bootstrap-vpn-certs.sh" --operator "$OPERATOR" --region "$REGION" 2>&1 | tee "$PKI_LOG"
    SERVER_ARN=$(grep -oE 'server_cert_arn[[:space:]]*=[[:space:]]*"arn:[^"]+"' "$PKI_LOG" | tail -1 | sed -E 's/.*"(arn:[^"]+)"/\1/')
    CLIENT_ARN=$(grep -oE 'client_cert_arn[[:space:]]*=[[:space:]]*"arn:[^"]+"' "$PKI_LOG" | tail -1 | sed -E 's/.*"(arn:[^"]+)"/\1/')
    [[ -n "$SERVER_ARN" && -n "$CLIENT_ARN" ]] || fail "Failed to parse cert ARNs from bootstrap output"
    cat > "$CERT_TFVARS" <<EOF
# Auto-generated by scripts/cloud-up.sh — do not edit manually.
# Regenerated on each fresh PKI bootstrap; deleted by cloud-down.sh after ACM cleanup.
server_cert_arn = "$SERVER_ARN"
client_cert_arn = "$CLIENT_ARN"
EOF
    rm -f "$PKI_LOG"
    ok "Wrote $CERT_TFVARS"
fi

# ─── Phase 2: ECR + image push (chicken-and-egg break) ─────────────────────
section "5/6 — ECR build + image push"
info "terraform init"
(cd "$TF_DIR" && terraform init -backend=false -input=false >/dev/null)
info "terraform apply -target=module.ecr (creates registry only)"
(cd "$TF_DIR" && terraform apply -target=module.ecr -auto-approve -input=false)
ECR_URL=$(cd "$TF_DIR" && terraform output -raw ecr_repository_url)
ok "ECR repository: $ECR_URL"

info "Logging into ECR ($REGION)"
aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin "$ECR_URL" >/dev/null
ok "Docker logged in to $ECR_URL"

info "Building image (--platform linux/amd64 for Fargate x86_64 default)"
(cd "$REPO_ROOT" && docker build --platform linux/amd64 -t "$ECR_URL:latest" .)
info "Pushing image"
docker push "$ECR_URL:latest" >/dev/null
ok "Image pushed: $ECR_URL:latest"

# ─── Phase 3: Full terraform apply ─────────────────────────────────────────
section "6/6 — Full terraform apply (Phase 2.5 cost timer starts now)"
info "Running 'make tf-apply' (= scripts/ts_apply.sh wrapper with 6 pre-flight checks)"
"$SCRIPT_DIR/ts_apply.sh"

# ─── Print operator next-steps ─────────────────────────────────────────────
section "Cloud is UP — next steps"
ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name 2>/dev/null || echo "(output not present)")
VPN_ID=$(cd "$TF_DIR"  && terraform output -raw client_vpn_endpoint_id 2>/dev/null || echo "(output not present)")

ELAPSED=$(($(date -u +%s) - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

cat <<EOF

  ALB DNS:     $ALB_DNS
  VPN endpoint: $VPN_ID
  Apply elapsed: ${ELAPSED_MIN}m ${ELAPSED_SEC}s

  Operator next steps:
    1. Download VPN client config:
       aws ec2 export-client-vpn-client-configuration \\
           --client-vpn-endpoint-id $VPN_ID \\
           --region $REGION \\
           --output text > pki/$OPERATOR.ovpn
       Append the operator's client cert + key (in pki/$OPERATOR/) into the .ovpn

    2. Connect via Tunnelblick or 'sudo openvpn --config pki/$OPERATOR.ovpn'

    3. Run smoke test:
       Capture the ALB CA pem + endpoint DNS, then:
         ALB_IP=\$(dig +short \$(cd terraform && terraform output -raw alb_dns_name) | head -1)
         cd terraform && terraform output -raw alb_self_signed_ca_pem > /tmp/alb-ca.pem
         CURL="curl --cacert /tmp/alb-ca.pem --resolve api.enclave.internal:443:\$ALB_IP"
         \$CURL https://api.enclave.internal/health
       (or wrap into scripts/cloud-smoke.sh — TODO)

    4. CloudWatch evidence capture (per memory feedback_phase25_screenshot_evidence.md):
       Screenshot dashboards BEFORE running 'make cloud-down'. Targets:
         - SQS ApproximateNumberOfMessagesVisible
         - ECS DesiredCount (worker autoscale)
         - ElastiCache BytesUsedForCache + ElastiCacheProcessingUnits
         - Worker CloudWatch logs + bootstrap task logs
         - 6/6 smoke test screenshots

    5. When done: 'make cloud-down' (drains ECR + destroys + cleans ACM certs)
       Cost budget reminder: ≤ 3h apply-then-destroy window (≈ \$1.20-1.80 per ADR-0031)

EOF
ok "cloud-up complete — Phase 2.5 cost timer is running"
