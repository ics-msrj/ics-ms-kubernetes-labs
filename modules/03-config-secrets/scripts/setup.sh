#!/bin/bash
# =============================================================================
# Module 03 — Config & Secrets — setup.sh
#
# 1. Installs kubeseal (CLI) if missing
# 2. Installs the Sealed Secrets controller
# 3. Applies the shared ConfigMap + the 6 Deployments that consume it
# 4. Generates a random Redis password, seals it against this cluster's
#    live controller, and applies the resulting SealedSecret — the plain
#    password is never written to disk
# 5. Applies the redis-cart StatefulSet (with auth) and cartservice (with
#    the matching connection string) on top of what Module 02 created
#
# Idempotent: safe to re-run. Re-running regenerates and reseals the Redis
# password every time — that's expected, not a bug (see README).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
GENERATED_DIR="${MODULE_DIR}/generated"

SEALED_SECRETS_VERSION="${SEALED_SECRETS_VERSION:-0.38.4}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get namespace online-boutique &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Namespace online-boutique not found. Complete Module 02 first." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 03 — Config & Secrets — Setup"
echo "============================================================"
echo ""

# --- Step 1: kubeseal CLI ---
if command -v kubeseal &>/dev/null; then
  log_info "kubeseal already installed: $(kubeseal --version 2>&1 | head -1)"
else
  log_info "Installing kubeseal v${SEALED_SECRETS_VERSION}..."
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH_RAW" >&2; exit 1 ;;
  esac
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  curl -fsSL -o "${TMP_DIR}/kubeseal.tar.gz" \
    "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${SEALED_SECRETS_VERSION}/kubeseal-${SEALED_SECRETS_VERSION}-${OS}-${ARCH}.tar.gz"
  tar -xzf "${TMP_DIR}/kubeseal.tar.gz" -C "$TMP_DIR" kubeseal
  sudo mv "${TMP_DIR}/kubeseal" /usr/local/bin/kubeseal
  log_ok "kubeseal installed"
fi

# --- Step 2: Sealed Secrets controller ---
log_info "Installing Sealed Secrets controller..."
kubectl apply -f "${MODULE_DIR}/manifests/sealed-secrets-controller.yaml"
kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=120s
log_ok "Sealed Secrets controller ready"

# --- Step 3: shared ConfigMap ---
log_info "Applying shared ConfigMap and the 6 Deployments that consume it..."
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/shared-config-configmap.yaml"
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/shared-config-deployments.yaml"
log_ok "ConfigMap applied"

# --- Step 4: seal a random Redis password ---
log_info "Generating a random Redis password and sealing it..."
mkdir -p "$GENERATED_DIR"
REDIS_PASSWORD="$(openssl rand -hex 16)"
kubectl create secret generic redis-cart-credentials \
  --namespace online-boutique \
  --from-literal=password="${REDIS_PASSWORD}" \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml --controller-namespace=kube-system --controller-name=sealed-secrets-controller \
  > "${GENERATED_DIR}/redis-cart-sealedsecret.yaml"
unset REDIS_PASSWORD
kubectl apply -n online-boutique -f "${GENERATED_DIR}/redis-cart-sealedsecret.yaml"
log_ok "SealedSecret applied — controller is decrypting it into a real Secret now"

log_info "Waiting for the controller to unseal it into a real Secret..."
for i in $(seq 1 15); do
  kubectl get secret redis-cart-credentials -n online-boutique &>/dev/null && break
  sleep 2
done
kubectl get secret redis-cart-credentials -n online-boutique &>/dev/null \
  && log_ok "Secret redis-cart-credentials exists" \
  || { echo -e "${RED}[ERROR]${NC} Secret never appeared — check: kubectl logs -n kube-system deployment/sealed-secrets-controller" >&2; exit 1; }

# --- Step 5: redis-cart with auth, cartservice with matching connection string ---
log_info "Enabling Redis AUTH on redis-cart..."
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/redis-cart-statefulset-with-auth.yaml"

log_info "Updating cartservice to authenticate to redis-cart..."
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/cartservice-with-redis-auth.yaml"

log_info "Waiting for rollouts..."
kubectl rollout status statefulset/redis-cart -n online-boutique --timeout=120s
kubectl rollout status deployment/cartservice -n online-boutique --timeout=120s
for dep in currencyservice productcatalogservice shippingservice emailservice paymentservice recommendationservice; do
  kubectl rollout status "deployment/${dep}" -n online-boutique --timeout=120s \
    || log_warn "${dep} not ready yet — check: kubectl get pods -n online-boutique"
done

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/03-config-secrets/scripts/verify.sh"
echo "============================================================"
echo ""
