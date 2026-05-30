#!/usr/bin/env bash
# cloud-up.sh — one-shot cloud deployment orchestrator for aegis-enclave.
#
# Sequences the operator's deploy workflow into a single command:
#   1. Pre-flight: AWS auth + docker daemon + terraform + tfvars present
#   2. VPN PKI provisioning (idempotent — skip if no PENDING: cert sentinels
#      remain in terraform.tfvars)
#   3. ECR-target apply + image build + push (chicken-and-egg break)
#   4. Full terraform apply (cloud-acceptance window starts here per ADR-0034)
#   5. Print operator next-steps (VPN config, ALB DNS, smoke command)
#
# Region interface (ADR-0042): terraform.tfvars carries `platform_region` plus
# a `regions` map. Cert ARNs live INSIDE each region's map entry. tfvars-init
# writes them as REGION-KEYED SENTINELS ("PENDING:server:<region>" /
# "PENDING:client:<region>"); this script bootstraps the VPN PKI per region and
# sed-substitutes the real ACM ARNs in place. No cert-arns.auto.tfvars file.
#
# Designed for a bounded apply-then-destroy window (per ADR-0034 + ADR-0031
# cost framing). Pair with `make cloud-down` for collateral-free teardown.
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
PKI_DIR="$REPO_ROOT/pki"
TFVARS="$TF_DIR/terraform.tfvars"

OPERATOR="${OPERATOR:-$(whoami)}"
START_TIME=$(date -u +%s)

section "aegis-enclave — cloud-up (cloud-acceptance window)"
echo "Operator:    $OPERATOR"
echo "Repo:        $REPO_ROOT"
echo "Terraform:   $TF_DIR"

# ─── Pre-flight: tools ─────────────────────────────────────────────────────
section "1/6 — Tool presence"
command -v terraform >/dev/null 2>&1 || fail "terraform not found in PATH (brew install terraform)"
command -v aws >/dev/null 2>&1       || fail "aws CLI not found in PATH (brew install awscli)"
command -v docker >/dev/null 2>&1    || fail "docker not found in PATH (install Docker Desktop or OrbStack)"
docker info >/dev/null 2>&1          || fail "docker daemon not running (start Docker Desktop / OrbStack?)"
# easy-rsa is required by scripts/bootstrap-vpn-certs.sh (called from Step 1
# below). Pre-flight here so we fail fast in pre-flight, not 10 minutes into
# the flow when bootstrap-vpn-certs.sh tries to invoke easyrsa and dies cryptically.
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

# Resolve AWS_PROFILE: env var > tfvars persisted > interactive prompt.
# Per memory feedback_explicit_over_implicit.md: read explicitly, log source.
# Subshell with `|| true` per feedback_pipefail_optional_input_must_or_true.md.
if [[ -z "${AWS_PROFILE:-}" ]] && [[ -f "$TFVARS" ]]; then
    AWS_PROFILE_FROM_TFVARS=$( (grep -E '^aws_profile[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')
    if [[ -n "$AWS_PROFILE_FROM_TFVARS" ]]; then
        export AWS_PROFILE="$AWS_PROFILE_FROM_TFVARS"
        info "Using AWS_PROFILE=$AWS_PROFILE (from $TFVARS)"
    fi
fi

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

# Region interface (ADR-0042): platform_region is a flat scalar; the peer
# region is whichever quoted `regions` map key is NOT the platform region.
# `terraform output` names (secondary_ecr_repository_url etc.) deliberately
# keep the "primary/secondary" wording — the SECONDARY_REGION var below maps
# the peer region onto those output names unchanged.
REGION=$( (grep -E '^platform_region[[:space:]]*=' "$TFVARS" 2>/dev/null || true) | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
REGION="${REGION:-eu-central-1}"
ok "Region (platform): $REGION"

# Peer region = the regions-map key that is not the platform region. Map keys
# are lines like `  "eu-west-1" = {`. Grep all quoted keys, drop the platform
# region, take the first remainder. Subshell + || true: a single-region map
# (only the platform key) legitimately yields no remainder.
SECONDARY_REGION=$( (grep -oE '^[[:space:]]*"[a-z]{2}-[a-z]+-[0-9]+"[[:space:]]*=[[:space:]]*\{' "$TFVARS" 2>/dev/null || true) \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | grep -vx "$REGION" \
    | head -1 || true )
if [[ -n "$SECONDARY_REGION" ]]; then
    ok "Region (peer): $SECONDARY_REGION (multi-region active-active mode)"
else
    info "no peer region in regions map — single-region mode"
fi

# ─── Step 1: VPN PKI provisioning (idempotent, multi-region) ───────────────
section "4/6 — VPN PKI + ACM import"

# bootstrap-vpn-certs.sh handles PKI generation idempotently and ACM import
# per --region. For multi-region we run it twice (same PKI, second region's
# ACM import-only path triggered by the bootstrap script's PKI_REUSED=1 branch).
#
# Cert ARNs live INSIDE each region's object in the single `regions` map. A
# .auto.tfvars file cannot partially override one map key, so the old
# cert-arns.auto.tfvars pattern is gone. Instead tfvars-init.sh wrote
# REGION-KEYED SENTINELS ("PENDING:server:<region>" / "PENDING:client:<region>")
# and this script sed-substitutes the real ACM ARNs in place.

# Helper: parse ARNs from bootstrap output log.
parse_arns_from_log() {
    local log="$1"
    SERVER_ARN=$(grep -oE 'server_cert_arn[[:space:]]*=[[:space:]]*"arn:[^"]+"' "$log" | tail -1 | sed -E 's/.*"(arn:[^"]+)"/\1/')
    CLIENT_ARN=$(grep -oE 'client_cert_arn[[:space:]]*=[[:space:]]*"arn:[^"]+"' "$log" | tail -1 | sed -E 's/.*"(arn:[^"]+)"/\1/')
}

# Helper: in-place substitute a region's PENDING sentinels with real ARNs.
# macOS sed needs the `-i ''` form (empty backup suffix). ARNs are plain
# alphanumerics + ':' + '/' + '-' so they are sed-replacement-safe; the
# sentinel pattern (PENDING:server:<region>) contains no regex metachars.
substitute_cert_arns() {
    local region="$1" server_arn="$2" client_arn="$3"
    sed -i '' \
        -e "s|PENDING:server:${region}|${server_arn}|g" \
        -e "s|PENDING:client:${region}|${client_arn}|g" \
        "$TFVARS"
}

# Helper: does $TFVARS still contain a given sentinel pattern?
# Returns 0 = present, 1 = absent. set -e safe: grep's exit code is consumed
# by `if`, so a no-match (exit 1) does not abort the script. The 2>/dev/null
# covers a (would-be unexpected) missing file without killing the run.
has_sentinel() {
    grep -q "$1" "$TFVARS" 2>/dev/null
}

# Idempotency: if no PENDING: sentinel remains anywhere, certs are filled in.
if ! has_sentinel 'PENDING:'; then
    ok "no PENDING: cert sentinels in $TFVARS — VPN certs already provisioned, skipping bootstrap"
else
    PKI_LOG="$REPO_ROOT/.cloud-up-pki-output.log"

    # Platform region — only bootstrap if its sentinels are still present.
    if has_sentinel "PENDING:server:${REGION}"; then
        info "Running bootstrap-vpn-certs.sh --operator $OPERATOR --region $REGION (platform)"
        "$SCRIPT_DIR/bootstrap-vpn-certs.sh" --operator "$OPERATOR" --region "$REGION" 2>&1 | tee "$PKI_LOG"
        parse_arns_from_log "$PKI_LOG"
        [[ -n "$SERVER_ARN" && -n "$CLIENT_ARN" ]] \
            || fail "Failed to parse platform-region cert ARNs from bootstrap output"
        substitute_cert_arns "$REGION" "$SERVER_ARN" "$CLIENT_ARN"
        ok "Substituted real ACM ARNs for $REGION in $TFVARS"
    else
        ok "$REGION cert sentinels already substituted — skipping platform bootstrap"
    fi

    # Peer region — same per-region sentinel check.
    if [[ -n "$SECONDARY_REGION" ]]; then
        if has_sentinel "PENDING:server:${SECONDARY_REGION}"; then
            info "Running bootstrap-vpn-certs.sh --operator $OPERATOR --region $SECONDARY_REGION (peer)"
            "$SCRIPT_DIR/bootstrap-vpn-certs.sh" --operator "$OPERATOR" --region "$SECONDARY_REGION" 2>&1 | tee "$PKI_LOG"
            parse_arns_from_log "$PKI_LOG"
            [[ -n "$SERVER_ARN" && -n "$CLIENT_ARN" ]] \
                || fail "Failed to parse peer-region cert ARNs from bootstrap output"
            substitute_cert_arns "$SECONDARY_REGION" "$SERVER_ARN" "$CLIENT_ARN"
            ok "Substituted real ACM ARNs for $SECONDARY_REGION in $TFVARS"
        else
            ok "$SECONDARY_REGION cert sentinels already substituted — skipping peer bootstrap"
        fi
    fi

    rm -f "$PKI_LOG"

    # Guard: every sentinel must be gone before the apply (apply needs real ARNs).
    if has_sentinel 'PENDING:'; then
        fail "PENDING: cert sentinels still in $TFVARS after bootstrap — substitution incomplete; check bootstrap output"
    fi
    ok "All cert sentinels substituted in $TFVARS"
fi

# ─── Step 2: Pre-deps apply + ECR + image push ────────────────────────────
# Two reasons for the staged -target apply:
#   1. ECR must exist before docker push (chicken-and-egg).
#   2. ECS module's container_definitions for_each fails at plan time when
#      aws_dynamodb_table.executions + the region-stack VPC outputs are unknown —
#      terraform infers the whole map as 'unknown' and bails ("for_each map
#      includes keys derived from resource attributes that cannot be determined
#      until apply"). Pre-applying VPC + DynamoDB table + ECR makes those refs
#      resolvable, the full apply then plans cleanly.
section "5/6 — Pre-deps apply + image push"
warn "🚨 Cost timer starts NOW — provisioning VPC + DynamoDB table + ECR (~1-2 min first time)"
info "terraform init"
(cd "$TF_DIR" && terraform init -backend=false -input=false >/dev/null)
# VPC + ECR live INSIDE the region-stack module (module.region_platform /
# module.region_peer[0]) after the ADR-0044 refactor — target them there, not
# at the root. For multi-region, pre-create the PEER ECR too so the image can
# be replicated to it before the full apply (the peer ECS pulls from it).
PREDEP_TARGETS=(
    -target=module.region_platform.module.vpc
    -target=module.region_platform.module.ecr
    -target=aws_dynamodb_table.executions
)
if [[ -n "$SECONDARY_REGION" ]]; then
    PREDEP_TARGETS+=(-target='module.region_peer[0].module.vpc' -target='module.region_peer[0].module.ecr')
fi
info "terraform apply ${PREDEP_TARGETS[*]} -auto-approve"
info "(VPC ~1 min, ECR ~10 sec, DynamoDB on-demand table ~10s — no AZ provisioning latency)"
(cd "$TF_DIR" && terraform apply "${PREDEP_TARGETS[@]}" -auto-approve -input=false)
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

# Multi-region: replicate the image tag to secondary ECR so secondary ECS can
# pull. Without this, secondary tasks fail with CannotPullContainerError and
# secondary ALB returns 503 (no healthy targets).
if [[ -n "$SECONDARY_REGION" ]]; then
    SECONDARY_ECR_URL=$(cd "$TF_DIR" && terraform output -raw secondary_ecr_repository_url 2>/dev/null || echo "")
    if [[ -n "$SECONDARY_ECR_URL" ]]; then
        info "Multi-region: replicating $IMAGE_TAG to secondary ECR ($SECONDARY_REGION)"
        if aws ecr describe-images --region "$SECONDARY_REGION" --repository-name aegis-enclave \
             --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
            ok "Secondary ECR already has '$IMAGE_TAG' — skipping replicate"
        else
            aws ecr get-login-password --region "$SECONDARY_REGION" | \
                docker login --username AWS --password-stdin "$SECONDARY_ECR_URL" >/dev/null \
                || fail "Docker login to secondary ECR failed"
            docker tag "$ECR_URL:$IMAGE_TAG" "$SECONDARY_ECR_URL:$IMAGE_TAG"
            docker push "$SECONDARY_ECR_URL:$IMAGE_TAG" >/dev/null \
                || fail "ECR push to secondary failed ($SECONDARY_ECR_URL:$IMAGE_TAG)"
            ok "Image replicated to secondary: $SECONDARY_ECR_URL:$IMAGE_TAG"
        fi
    else
        warn "secondary_region set but secondary_ecr_repository_url output missing — secondary ECS will fail to pull"
    fi
fi

# ─── Step 3: Full terraform apply (remaining ~70 resources) ───────────────
section "6/6 — Full terraform apply (remaining resources)"
info "Pre-deps already applied above. ts_apply.sh will plan + prompt for the rest"
info "(Client VPN, ALB, ECS service, Valkey, SQS, IAM, autoscaling, VPC endpoints)"
"$SCRIPT_DIR/ts_apply.sh"

# ─── Auto-generate ready-to-connect .ovpn files (one per region) ───────────
# AWS-exported .ovpn does NOT include the client cert + key; openvpn refuses
# without them ("No client-side authentication method is specified"). Append
# them inline so operator can `sudo openvpn --config pki/<file>.ovpn` directly,
# no manual heredoc step.
section "Generating VPN client configs (one per region)"
generate_ovpn() {
    local region="$1"
    local vpn_id="$2"
    local out="$PKI_DIR/${OPERATOR}-${region}.ovpn"

    if [[ -z "$vpn_id" ]] || [[ "$vpn_id" == "(output not present)" ]]; then
        warn "skipping $region: VPN endpoint ID not in terraform output"
        return
    fi

    info "exporting VPN config: $region → $out"
    aws ec2 export-client-vpn-client-configuration \
        --profile "$AWS_PROFILE" --region "$region" \
        --client-vpn-endpoint-id "$vpn_id" \
        --output text > "$out"

    # Append client cert + key for mutual-TLS auth
    {
        echo
        echo '<cert>'
        cat "$PKI_DIR/pki/issued/${OPERATOR}.crt"
        echo '</cert>'
        echo '<key>'
        cat "$PKI_DIR/pki/private/${OPERATOR}.key"
        echo '</key>'
    } >> "$out"

    chmod 600 "$out"  # contains private key — restrict perms
    ok "ready: sudo openvpn --config $out"
}

PRIMARY_VPN_ID=$(cd "$TF_DIR" && terraform output -raw client_vpn_endpoint_id 2>/dev/null || echo "")
generate_ovpn "$REGION" "$PRIMARY_VPN_ID"

if [[ -n "$SECONDARY_REGION" ]]; then
    SECONDARY_VPN_ID=$(cd "$TF_DIR" && terraform output -raw secondary_client_vpn_endpoint_id 2>/dev/null || echo "")
    generate_ovpn "$SECONDARY_REGION" "$SECONDARY_VPN_ID"
fi

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

    1. VPN client configs already generated (cert + key inlined, ready to use):
         primary:   pki/${OPERATOR}-${REGION}.ovpn
$(if [[ -n "$SECONDARY_REGION" ]]; then echo "         secondary: pki/${OPERATOR}-${SECONDARY_REGION}.ovpn"; fi)

    2. Connect to ONE region at a time (don't mount both VPNs simultaneously —
       macOS routing collision):
         sudo openvpn --config pki/${OPERATOR}-${REGION}.ovpn
$(if [[ -n "$SECONDARY_REGION" ]]; then echo "       (or for secondary): sudo openvpn --config pki/${OPERATOR}-${SECONDARY_REGION}.ovpn"; fi)

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

ok "cloud-up complete — cloud-acceptance window cost timer is running"
