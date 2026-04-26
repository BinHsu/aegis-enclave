#!/usr/bin/env bash
# bootstrap-vpn-certs.sh — Generate the Client VPN PKI and import into ACM.
#
# Implements the cert-provisioning workflow from ADR-0024:
#   easy-rsa local PKI  →  ACM imported certificates  →  tfvars-ready ARNs
#
# Outputs:
#   1. ./pki/                    — full easy-rsa PKI tree (gitignored, chmod 700)
#   2. ACM imported server cert  — printed as `server_cert_arn = "..."`
#   3. ACM imported CA root      — printed as `client_cert_arn = "..."`
#   4. ./pki/<operator>/         — per-operator client cert + key for distribution
#
# Usage:
#   ./scripts/bootstrap-vpn-certs.sh --operator bin.hsu
#   ./scripts/bootstrap-vpn-certs.sh --operator bin.hsu --operator alice --region eu-central-1
#   ./scripts/bootstrap-vpn-certs.sh --force  # overwrite existing pki/ (CA destruction!)
#
# Idempotent: re-running with the same operators is a no-op (ACM re-import
# produces the same ARN). New operator names trigger fresh client cert issuance.
#
# See ADR-0024 for the full rationale (why not ACM PCA, why mutual-TLS, etc.).

set -euo pipefail

# ─── Colour output (degrades cleanly if NO_COLOR or non-TTY) ─────────────────
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    readonly RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m'
    readonly BOLD=$'\033[1m' RESET=$'\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

ok()      { printf "${GREEN}\xe2\x9c\x93${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}\xe2\x9a\xa0${RESET} %s\n" "$*" >&2; }
fail()    { printf "${RED}\xe2\x9c\x97${RESET} %s\n" "$*" >&2; exit 1; }
info()    { printf "${BLUE}\xe2\x86\x92${RESET} %s\n" "$*"; }
section() { printf "\n${BOLD}── %s ──${RESET}\n" "$*"; }

# ─── Locate repo root + paths ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKI_DIR="$REPO_ROOT/pki"

# ─── Argument parsing ────────────────────────────────────────────────────────
declare -a OPERATORS=()
REGION="${AWS_REGION:-eu-central-1}"
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --operator)
            [[ -z "${2:-}" ]] && fail "--operator requires a name"
            OPERATORS+=("$2")
            shift 2
            ;;
        --region)
            [[ -z "${2:-}" ]] && fail "--region requires a value"
            REGION="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *)
            fail "unknown argument: $1 (try --help)"
            ;;
    esac
done

[[ ${#OPERATORS[@]} -gt 0 ]] || fail "at least one --operator is required"

# ─── Banner ──────────────────────────────────────────────────────────────────
section "aegis-enclave — Client VPN cert bootstrap"
echo "Repo:       $REPO_ROOT"
echo "PKI dir:    $PKI_DIR"
echo "Region:     $REGION"
echo "Operators:  ${OPERATORS[*]}"
echo

# ─── Tool presence ───────────────────────────────────────────────────────────
section "1/6 — Tool presence"
EASYRSA="${EASYRSA:-easyrsa}"
if ! command -v "$EASYRSA" >/dev/null 2>&1; then
    fail "easyrsa not found in PATH.

      macOS:   brew install easy-rsa
      Debian:  sudo apt-get install easy-rsa
      Other:   https://github.com/OpenVPN/easy-rsa"
fi
ok "easyrsa: $($EASYRSA version | head -1)"

command -v aws     >/dev/null 2>&1 || fail "aws CLI not found in PATH"
command -v openssl >/dev/null 2>&1 || fail "openssl not found in PATH"
ok "aws CLI: $(aws --version 2>&1 | head -1)"
ok "openssl: $(openssl version)"

# ─── AWS authentication ──────────────────────────────────────────────────────
section "2/6 — AWS authentication"
CALLER_JSON=$(aws sts get-caller-identity --output json 2>&1) \
    || fail "aws sts get-caller-identity failed:
$CALLER_JSON"
ACCOUNT_ID=$(echo "$CALLER_JSON" | grep -oE '"Account":[^,}]*' | sed -E 's/.*"([0-9]+)".*/\1/')
ARN=$(echo "$CALLER_JSON" | grep -oE '"Arn":[^,}]*' | sed -E 's/"Arn":[[:space:]]*"(.+)"/\1/')
ok "account: $ACCOUNT_ID"
ok "caller:  $ARN"

# ─── PKI directory hygiene ───────────────────────────────────────────────────
section "3/6 — PKI directory hygiene"
if [[ -d "$PKI_DIR" ]] && [[ $FORCE -eq 0 ]]; then
    fail "$PKI_DIR exists and --force not given.

      Re-running on an existing PKI is supported for ADDING operators only:
        ./scripts/bootstrap-vpn-certs.sh --operator new-person

      To DESTROY and rebuild the CA (revokes all existing client access):
        rm -rf $PKI_DIR
        ./scripts/bootstrap-vpn-certs.sh --operator ... --force"
fi

# Create with restrictive perms — root key custody matters (ADR-0024 § Security posture)
mkdir -p "$PKI_DIR"
chmod 700 "$PKI_DIR"
ok "pki dir: $PKI_DIR (chmod 700)"

# ─── easy-rsa: init + build CA + server cert ─────────────────────────────────
section "4/6 — easy-rsa PKI build"

# Force easyrsa to write into OUR pki dir, not brew's default
# /opt/homebrew/etc/easy-rsa/pki (which is what easy-rsa 3.x ships with on
# macOS via brew). Without this, certs end up in shared system path → ACM
# import line later can't find them. Per memory feedback_explicit_over_implicit.
export EASYRSA_PKI="$PKI_DIR/pki"
mkdir -p "$EASYRSA_PKI"
info "EASYRSA_PKI=$EASYRSA_PKI (overrides brew default /opt/homebrew/etc/easy-rsa/pki)"

cd "$PKI_DIR"

if [[ ! -f "$EASYRSA_PKI/ca.crt" ]]; then
    info "init-pki + build-ca (one-time)"
    $EASYRSA --batch init-pki >/dev/null
    $EASYRSA --batch --req-cn="aegis-enclave-ca" build-ca nopass >/dev/null
    [[ -f "$EASYRSA_PKI/ca.crt" ]] || fail "build-ca succeeded but ca.crt not found at $EASYRSA_PKI/ca.crt"
    ok "CA built: $EASYRSA_PKI/ca.crt"

    info "build server cert (CN=server)"
    $EASYRSA --batch --san=DNS:server build-server-full server nopass >/dev/null
    [[ -f "$EASYRSA_PKI/issued/server.crt" ]] || fail "build-server-full ran but server.crt not found at $EASYRSA_PKI/issued/server.crt"
    [[ -f "$EASYRSA_PKI/private/server.key" ]] || fail "build-server-full ran but server.key not found"
    ok "server cert: $EASYRSA_PKI/issued/server.crt"
else
    ok "CA + server cert already exist (re-using)"
fi

# Per-operator client certs (idempotent — easyrsa skips if cert exists)
for OP in "${OPERATORS[@]}"; do
    if [[ -f "$EASYRSA_PKI/issued/$OP.crt" ]]; then
        ok "client cert exists: $OP"
    else
        info "build client cert: $OP"
        $EASYRSA --batch build-client-full "$OP" nopass >/dev/null
        [[ -f "$EASYRSA_PKI/issued/$OP.crt" ]] || fail "build-client-full $OP ran but cert not found at $EASYRSA_PKI/issued/$OP.crt"
        ok "client cert: $EASYRSA_PKI/issued/$OP.crt"
    fi
done

cd "$REPO_ROOT"

# ─── ACM import: server cert ─────────────────────────────────────────────────
section "5/6 — ACM import: server certificate"
SERVER_ARN=$(aws acm import-certificate \
    --region "$REGION" \
    --certificate     "fileb://$PKI_DIR/pki/issued/server.crt" \
    --private-key     "fileb://$PKI_DIR/pki/private/server.key" \
    --certificate-chain "fileb://$PKI_DIR/pki/ca.crt" \
    --output text \
    --query CertificateArn 2>&1) \
    || fail "ACM server cert import failed:
$SERVER_ARN"
ok "server_cert_arn: $SERVER_ARN"

# ─── ACM import: CA root ─────────────────────────────────────────────────────
section "6/6 — ACM import: CA root (for mutual-TLS client validation)"
# Client VPN's "client_cert_arn" actually wants the CA ROOT — the cert that
# signed the client certs. AWS validates client certs by checking the chain
# back to this root.
CLIENT_ARN=$(aws acm import-certificate \
    --region "$REGION" \
    --certificate "fileb://$PKI_DIR/pki/ca.crt" \
    --private-key "fileb://$PKI_DIR/pki/private/ca.key" \
    --output text \
    --query CertificateArn 2>&1) \
    || fail "ACM CA root import failed:
$CLIENT_ARN"
ok "client_cert_arn: $CLIENT_ARN"

# ─── Output summary ──────────────────────────────────────────────────────────
section "Done — paste into terraform/terraform.tfvars"
cat <<EOF
region          = "$REGION"
server_cert_arn = "$SERVER_ARN"
client_cert_arn = "$CLIENT_ARN"
EOF

echo
section "Per-operator artefacts (distribute privately)"
for OP in "${OPERATORS[@]}"; do
    echo "  $OP:"
    echo "    cert:     $PKI_DIR/pki/issued/$OP.crt"
    echo "    key:      $PKI_DIR/pki/private/$OP.key"
    echo "    ca:       $PKI_DIR/pki/ca.crt"
done

cat <<EOF

${BOLD}Next steps:${RESET}
  1. Paste the three lines above into terraform/terraform.tfvars
  2. Run ./scripts/ts_apply.sh (it will verify the ARNs are reachable)
  3. After apply, generate .ovpn files for each operator using the
     Client VPN endpoint hostname from \`terraform output\`.

${BOLD}Security:${RESET}
  - $PKI_DIR/pki/private/ca.key is the CA root key. Treat it like an
    AWS root account password. \`pki/\` is gitignored; keep it out of
    backups that aren't encrypted.
  - To revoke an operator: re-issue the CA. easy-rsa CRL automation is
    out of scope for this bootstrap (ADR-0024 § Consequences).
EOF
