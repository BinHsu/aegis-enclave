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
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH (brew install terraform)"
command -v aws >/dev/null 2>&1       || fail "aws CLI not found in PATH (brew install awscli)"
command -v docker >/dev/null 2>&1    || fail "docker not found in PATH (install Docker Desktop or OrbStack)"
docker info >/dev/null 2>&1          || fail "docker daemon not running (start Docker Desktop / OrbStack?)"
# easy-rsa is required by scripts/bootstrap-vpn-certs.sh (called from phase 4
# below). Pre-flight here so we fail fast in step 1, not 10 minutes into the
# flow when bootstrap-vpn-certs.sh tries to invoke easyrsa and dies cryptically.
command -v easyrsa >/dev/null 2>&1   || fail "easyrsa not found in PATH (brew install easy-rsa) — required by bootstrap-vpn-certs.sh"
ok "terraform / aws / docker / easy-rsa all present and ready"

# ─── Pre-flight: AWS authentication (source-agnostic; SSO recommended) ────
# We don't care if the profile is SSO-configured or uses long-term creds —
# we only care that 'aws sts get-caller-identity' works. SSO is recommended
# (refreshable, short-lived tokens, audit trail) but long-term creds also work.
# See memory feedback_aws_creds_agnostic.md.
section "2/6 — AWS authentication"

# Helper: list available profiles + sso-sessions so operator picks from a visible
# menu instead of guessing (per memory feedback_explicit_over_implicit.md).
PROFILES_AVAIL=$(aws configure list-profiles 2>/dev/null || true)
SSO_SESSIONS_AVAIL=$(grep -E '^\[sso-session ' ~/.aws/config 2>/dev/null | sed 's/^\[sso-session \(.*\)\]/\1/' || true)

if [[ -z "${AWS_PROFILE:-}" ]]; then
    if [[ -n "$PROFILES_AVAIL" ]]; then
        printf "Available AWS profiles:\n"
        echo "$PROFILES_AVAIL" | sed 's/^/  - /'
    fi
    if [[ -n "$SSO_SESSIONS_AVAIL" ]]; then
        printf "SSO sessions (NOT profiles — for reference only; pick a profile above):\n"
        echo "$SSO_SESSIONS_AVAIL" | sed 's/^/  - /'
    fi
    printf "Enter AWS_PROFILE [default]: "
    read -r AWS_PROFILE_INPUT
    export AWS_PROFILE="${AWS_PROFILE_INPUT:-default}"
fi
info "Using AWS_PROFILE=$AWS_PROFILE"

# Validate profile early if list available — fail fast on typo, not after sts
if [[ -n "$PROFILES_AVAIL" ]] && ! echo "$PROFILES_AVAIL" | grep -qx "$AWS_PROFILE"; then
    printf "\nProfile '%s' is NOT in 'aws configure list-profiles'. Available:\n" "$AWS_PROFILE" >&2
    echo "$PROFILES_AVAIL" | sed 's/^/  - /' >&2
    fail "Re-run and pick from the list above (typo, or use 'aws configure sso --profile <new>' to create)"
fi

# Always offer SSO refresh (per Bin: Enter = skip = "I have a token").
if [[ -n "$SSO_SESSIONS_AVAIL" ]]; then
    printf "Available SSO sessions:\n"
    echo "$SSO_SESSIONS_AVAIL" | sed 's/^/  - /'
fi
printf "SSO session name to refresh token (Enter to skip if you already have a valid token): "
read -r SSO_SESSION_INPUT
if [[ -n "$SSO_SESSION_INPUT" ]]; then
    info "Running: aws sso login --sso-session $SSO_SESSION_INPUT"
    aws sso login --sso-session "$SSO_SESSION_INPUT" || fail "SSO login failed for session $SSO_SESSION_INPUT"
fi

# Now try sts. If fails, diagnose (profile missing? creds bad?) and stop.
AUTH_RAW=""
AUTH_RC=0
AUTH_RAW=$(aws sts get-caller-identity 2>&1) || AUTH_RC=$?

if [[ "$AUTH_RC" -ne 0 ]]; then
    printf "\n--- aws sts get-caller-identity --profile %s failed (exit %d) ---\n%s\n--- end ---\n" \
        "$AWS_PROFILE" "$AUTH_RC" "$AUTH_RAW" >&2

    if ! aws configure list-profiles 2>/dev/null | grep -qx "$AWS_PROFILE"; then
        printf "\nProfile '%s' is NOT in 'aws configure list-profiles'.\n" "$AWS_PROFILE" >&2
        printf "Available profiles:\n" >&2
        aws configure list-profiles 2>/dev/null | sed 's/^/  - /' >&2
        printf "\nSSO sessions in your config:\n" >&2
        (grep -E '^\[sso-session ' ~/.aws/config 2>/dev/null | sed 's/^\[sso-session \(.*\)\]/  - \1/' || echo "  (none)") >&2
        fail "Profile '$AWS_PROFILE' does not exist — pick one from the list above"
    fi

    fail "AWS auth failed for profile '$AWS_PROFILE'. If your SSO token expired, re-run cloud-up and enter your sso-session name at the prompt."
fi

# Parse account info — defensive (set -e + pipefail would silently abort on grep no-match).
# Use a subshell with explicit fallback so an unexpected sts JSON shape can't kill the script.
ACCOUNT_ID=$( ( printf '%s' "$AUTH_RAW" | grep -oE '"Account":[[:space:]]*"[0-9]+"' | grep -oE '[0-9]+' | head -1 ) 2>/dev/null || echo "?" )
ARN=$( ( printf '%s' "$AUTH_RAW" | grep -oE '"Arn":[[:space:]]*"[^"]+"' | sed -E 's/.*"(arn:[^"]+)".*/\1/' | head -1 ) 2>/dev/null || echo "?" )
[[ -z "$ACCOUNT_ID" ]] && ACCOUNT_ID="?"
[[ -z "$ARN" ]] && ARN="?"
ok "AWS account: $ACCOUNT_ID"
ok "AWS caller:  $ARN"
info "Tip: to run 'aws ...' directly in this terminal (outside make targets), set:"
info "     export AWS_PROFILE=$AWS_PROFILE"

# ─── Pre-flight: tfvars present (interactive Q&A if missing) ──────────────
section "3/6 — tfvars present"
if [[ ! -f "$TFVARS" ]]; then
    info "$TFVARS missing — running interactive tfvars-init"
    "$SCRIPT_DIR/tfvars-init.sh"
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

# ─── Phase 2: Pre-deps apply + ECR + image push ────────────────────────────
# Two reasons for the staged -target apply:
#   1. ECR must exist before docker push (chicken-and-egg).
#   2. ECS module's container_definitions for_each fails at plan time when
#      aws_dynamodb_table.executions + module.vpc outputs are unknown —
#      terraform infers the whole map as 'unknown' and bails ("for_each map
#      includes keys derived from resource attributes that cannot be determined
#      until apply"). Pre-applying VPC + DynamoDB table + ECR makes those refs
#      resolvable, the full apply then plans cleanly.
section "5/6 — Pre-deps apply + image push"
warn "🚨 Cost timer starts NOW — provisioning VPC + DynamoDB table + ECR (~1-2 min first time)"
info "terraform init"
(cd "$TF_DIR" && terraform init -backend=false -input=false >/dev/null)
info "terraform apply -target=module.vpc -target=aws_dynamodb_table.executions -target=module.ecr -auto-approve"
info "(VPC ~1 min, ECR ~10 sec, DynamoDB on-demand table ~10s — no AZ provisioning latency)"
(cd "$TF_DIR" && terraform apply \
    -target=module.vpc -target=aws_dynamodb_table.executions -target=module.ecr \
    -auto-approve -input=false)
ECR_URL=$(cd "$TF_DIR" && terraform output -raw ecr_repository_url)
ok "Pre-deps applied. ECR repository: $ECR_URL"

info "Logging into ECR ($REGION)"
aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin "$ECR_URL" >/dev/null
ok "Docker logged in to $ECR_URL"

# Compute content-specific image tag — git short SHA for clean trees, with
# dirty suffix (content hash) for uncommitted changes. Avoids ECR IMMUTABLE
# collisions across re-runs (same content → same tag → ECR no-op push;
# different content → different tag → fresh push).
GIT_SHA=$(cd "$REPO_ROOT" && git rev-parse --short=8 HEAD 2>/dev/null || echo "notag")
DIRTY=""
if [[ -n "$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null)" ]]; then
    DIRTY_HASH=$(cd "$REPO_ROOT" && git diff HEAD 2>/dev/null | shasum -a 256 | head -c 8)
    DIRTY="-dirty-${DIRTY_HASH}"
    warn "working tree has uncommitted changes — using dirty-suffixed tag"
fi
IMAGE_TAG="${GIT_SHA}${DIRTY}"
info "Image tag: $IMAGE_TAG"

# Persist to image-tag.auto.tfvars so terraform apply uses the same tag we just built.
cat > "$TF_DIR/image-tag.auto.tfvars" <<EOF
# Auto-generated by scripts/cloud-up.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Maps ECS task definitions to the just-built image. Removed by cloud-down.sh.
image_tag = "$IMAGE_TAG"
EOF
ok "wrote $TF_DIR/image-tag.auto.tfvars (image_tag=$IMAGE_TAG)"

# Pre-check: does this tag already exist in ECR? Skip build+push entirely if yes.
# With content-derived tags (git-sha or git-sha+content-hash), tag-exists ⇒ same
# content. No need to rebuild, no need to push, no IMMUTABLE conflict.
info "Checking if $IMAGE_TAG already in ECR..."
if aws ecr describe-images --region "$REGION" --repository-name aegis-enclave \
     --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
    ok "ECR tag '$IMAGE_TAG' already exists — skipping build + push (no-op)"
    ok "Image already in ECR: $ECR_URL:$IMAGE_TAG"
else
    info "Tag '$IMAGE_TAG' not in ECR — building + pushing"
    info "Building image (--platform linux/amd64 for Fargate; --provenance=false for deterministic digest)"
    # --provenance=false + --sbom=false: BuildKit attestation embeds build-time
    # metadata into the manifest, making same-content rebuilds produce different
    # digests. Without these, the pre-check above couldn't be content-correct.
    (cd "$REPO_ROOT" && docker build --platform linux/amd64 --provenance=false --sbom=false -t "$ECR_URL:$IMAGE_TAG" .)

    info "Pushing image: $ECR_URL:$IMAGE_TAG"
    PUSH_RC=0
    PUSH_RAW=$(docker push "$ECR_URL:$IMAGE_TAG" 2>&1) || PUSH_RC=$?
    if [[ "$PUSH_RC" -ne 0 ]]; then
        printf "\n--- docker push failed ---\n%s\n--- end ---\n" "$PUSH_RAW" >&2
        if echo "$PUSH_RAW" | grep -qiE 'tag.*already exists.*immutable|cannot be overwritten'; then
            # Race: tag created between describe-images and push. Or content hash
            # collision (extremely rare). Either way, drop the tag and retry.
            printf "\nTag was created between pre-check and push (race), or content hash collision.\n" >&2
            printf "Recovery: aws ecr batch-delete-image --region %s --repository-name aegis-enclave --image-ids imageTag=%s\n" "$REGION" "$IMAGE_TAG" >&2
        fi
        fail "ECR push failed"
    fi
    ok "Image pushed: $ECR_URL:$IMAGE_TAG"
fi

# ─── Phase 3: Full terraform apply (remaining ~70 resources) ───────────────
section "6/6 — Full terraform apply (remaining resources)"
info "Pre-deps already applied above. ts_apply.sh will plan + prompt for the rest"
info "(Client VPN, ALB, ECS service, Valkey, SQS, IAM, autoscaling, VPC endpoints)"
"$SCRIPT_DIR/ts_apply.sh"

# ─── Print operator next-steps ─────────────────────────────────────────────
section "Cloud is UP — next steps"
ALB_DNS=$(cd "$TF_DIR" && terraform output -raw alb_dns_name 2>/dev/null || echo "(output not present)")
VPN_ID=$(cd "$TF_DIR"  && terraform output -raw client_vpn_endpoint_id 2>/dev/null || echo "(output not present)")

# Read the literal alarm_email value the operator entered at tfvars-init time
# so the SNS confirmation reminder is not vague ("check your email") but
# explicit ("check the inbox of <address>"). Empty value → no reminder.
ALARM_EMAIL=$(grep -E '^alarm_email[[:space:]]*=' "$TFVARS" 2>/dev/null \
              | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || echo "")

ELAPSED=$(($(date -u +%s) - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

cat <<EOF

  ALB DNS:     $ALB_DNS
  VPN endpoint: $VPN_ID
  Apply elapsed: ${ELAPSED_MIN}m ${ELAPSED_SEC}s

  Operator next steps (commands include --profile so they're copy-paste safe;
  AWS_PROFILE export inside this script is subshell-only and doesn't carry
  back to your terminal):

    1. Download VPN client config (single-line, copy-paste safe):
       aws ec2 export-client-vpn-client-configuration --profile $AWS_PROFILE --region $REGION --client-vpn-endpoint-id $VPN_ID --output text > pki/$OPERATOR.ovpn
       Append the operator's client cert + key (in pki/$OPERATOR/) into the .ovpn

    2. Connect via Tunnelblick or 'sudo openvpn --config pki/$OPERATOR.ovpn'

    3. Run smoke test:
         AWS_PROFILE=$AWS_PROFILE make cloud-smoke
       (or manually, single-line:
         CA=/tmp/alb-ca.pem; cd terraform && terraform output -raw alb_self_signed_ca_pem > \$CA && ALB_IP=\$(dig +short \$(terraform output -raw alb_dns_name) | head -1) && cd .. && curl --cacert \$CA --resolve api.enclave.internal:443:\$ALB_IP https://api.enclave.internal/health)

    4. CloudWatch evidence capture (per memory feedback_phase25_screenshot_evidence.md):
         AWS_PROFILE=$AWS_PROFILE make cloud-evidence
       Captures via API path (cloudwatch:GetMetricWidgetImage + DescribeAlarms);
       works under cloudwatch:ListMetrics SCP deny since it doesn't depend on
       Console UI. AWS Console UI for the SLO dashboard MAY be SCP-blocked at
       the org level — that is expected; the API path is the canonical source.
       Targets captured into evidence/<TS>/:
         - metrics/   AWS-native panels (SQS / ECS / Valkey / ALB / DynamoDB)
         - slo/       Application SLI panels (latency / error rate / cache hit
                      ratio / compute duration / volume / alarm state JSON)
         - logs/      Worker + bootstrap CloudWatch logs + cache_hit:compute_done
                      counters + bootstrap idempotency counters
         - terraform-output.json   Full state surface

    5. When done:
         AWS_PROFILE=$AWS_PROFILE make cloud-down
       (drains ECR + destroys + cleans ACM certs + collateral-free verify)
       Cost budget reminder: ≤ 3h apply-then-destroy window (≈ \$0.84/h steady-state per
       README cost table; 3h ≈ \$2.50 actual)

EOF

# ADR-0041: SNS subscription requires the recipient to click a confirmation
# link in the AWS-sent email. Until they do, the subscription is in
# 'PendingConfirmation' state and notifications don't deliver. Print the
# literal email address (from tfvars) so the operator knows which inbox to
# check, not just a vague "check your email".
if [[ -n "$ALARM_EMAIL" ]]; then
    section "⚠ Action required — SNS subscription confirmation"
    cat <<EOF

  An email from "AWS Notification - Subscription Confirmation" was sent to:

    ${BOLD}${ALARM_EMAIL}${RESET}

  Open that inbox and click the "Confirm subscription" link before triggering
  any test alarm. Until you confirm, alarms still fire and log to EventBridge,
  but email notifications will NOT deliver.

  After confirming, you can verify by triggering a deliberate test alarm:

    aws cloudwatch set-alarm-state --profile $AWS_PROFILE --region $REGION \\
        --alarm-name aegis-enclave-slo-fast-burn \\
        --state-value ALARM \\
        --state-reason "manual smoke test"

  You should receive an email titled "ALARM: aegis-enclave-slo-fast-burn".
  Reset the alarm state to OK after verification:

    aws cloudwatch set-alarm-state --profile $AWS_PROFILE --region $REGION \\
        --alarm-name aegis-enclave-slo-fast-burn \\
        --state-value OK \\
        --state-reason "test complete"

EOF
fi

ok "cloud-up complete — Phase 2.5 cost timer is running"
