#!/bin/bash
# =============================================================================
# Module 04 — Networking & Gateway API — setup.sh
#
# 1. Installs Gateway API CRDs, then enables Cilium's Gateway API support
#    (hostNetwork mode — no cloud LoadBalancer needed)
# 2. Installs cert-manager
# 3. Applies ClusterIssuers (selfsigned always; Let's Encrypt ones only if
#    ACME_EMAIL is set)
# 4. Applies the Gateway + HTTPRoute for frontend, templated with
#    APP_DOMAIN/TLS_ISSUER from lab.env
# 5. Applies the redis-cart NetworkPolicy
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-1.6.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.21.0}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.5}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"

APP_DOMAIN="${APP_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get namespace online-boutique &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Namespace online-boutique not found. Complete Module 02 first." >&2
  exit 1
fi
if [[ -z "$APP_DOMAIN" || "$APP_DOMAIN" == "shop.example.com" ]]; then
  echo -e "${RED}[ERROR]${NC} Set a real APP_DOMAIN in lab.env before running this module." >&2
  exit 1
fi
if [[ "$TLS_ISSUER" != "selfsigned" && -z "$ACME_EMAIL" ]]; then
  echo -e "${RED}[ERROR]${NC} TLS_ISSUER=${TLS_ISSUER} needs ACME_EMAIL set in lab.env." >&2
  echo "  No real domain to validate against Let's Encrypt? Run instead:" >&2
  echo "  TLS_ISSUER=selfsigned bash modules/04-networking-gateway/scripts/setup.sh" >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 04 — Networking & Gateway API — Setup"
echo "  Domain: ${APP_DOMAIN}   TLS issuer: ${TLS_ISSUER}"
echo "============================================================"
echo ""

# --- Step 1: Gateway API CRDs ---
log_info "Installing Gateway API CRDs v${GATEWAY_API_VERSION}..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/standard-install.yaml"
log_ok "Gateway API CRDs installed"

# --- Step 2: enable Cilium's Gateway API support ---
log_info "Enabling Gateway API support in Cilium (hostNetwork mode)..."
helm repo add cilium https://helm.cilium.io/ &>/dev/null || true
helm repo update cilium &>/dev/null
helm upgrade cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --reuse-values \
  --set gatewayAPI.enabled=true \
  --set gatewayAPI.hostNetwork.enabled=true

log_info "Waiting for Cilium to roll out with Gateway API enabled..."
kubectl rollout status daemonset/cilium -n kube-system --timeout=180s
kubectl wait gatewayclass cilium --for=condition=Accepted --timeout=60s \
  || log_warn "GatewayClass 'cilium' not Accepted yet — check: kubectl describe gatewayclass cilium"
log_ok "Cilium Gateway API enabled"

# --- Step 3: cert-manager ---
if kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
  log_info "cert-manager already installed — skipping"
else
  log_info "Installing cert-manager v${CERT_MANAGER_VERSION}..."
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
  helm repo add jetstack https://charts.jetstack.io &>/dev/null || true
  helm repo update jetstack &>/dev/null
  # config.gatewayAPI.enabled=true turns on cert-manager's gateway-shim —
  # without it the controller never watches Gateway resources at all, so
  # the Certificate the Gateway annotation below expects is never created.
  # Defaults to config: {} (disabled) on the chart, easy to miss since the
  # install otherwise succeeds silently.
  helm install cert-manager jetstack/cert-manager \
    --version "v${CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace \
    --set config.gatewayAPI.enabled=true
fi
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=120s
log_ok "cert-manager ready"

# --- Step 4: ClusterIssuers ---
log_info "Applying ClusterIssuers..."
kubectl apply -f "${MODULE_DIR}/manifests/clusterissuer-selfsigned.yaml"
if [[ -n "$ACME_EMAIL" ]]; then
  sed "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "${MODULE_DIR}/manifests/clusterissuer-letsencrypt-staging.yaml" | kubectl apply -f -
  sed "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "${MODULE_DIR}/manifests/clusterissuer-letsencrypt-production.yaml" | kubectl apply -f -
fi
log_ok "ClusterIssuers applied"

# --- Step 5: Gateway + HTTPRoute, templated ---
log_info "Applying Gateway (issuer: ${TLS_ISSUER}) and HTTPRoute (host: ${APP_DOMAIN})..."
sed "s|__TLS_ISSUER__|${TLS_ISSUER}|g" "${MODULE_DIR}/manifests/gateway.yaml" | kubectl apply -f -
sed "s|__APP_DOMAIN__|${APP_DOMAIN}|g" "${MODULE_DIR}/manifests/httproute-frontend.yaml" | kubectl apply -f -
log_ok "Gateway and HTTPRoute applied"

# --- Step 6: NetworkPolicy ---
log_info "Locking down redis-cart to cartservice only..."
kubectl apply -f "${MODULE_DIR}/manifests/networkpolicy-redis-cart.yaml"
log_ok "NetworkPolicy applied"

# --- Step 7: wait for the Gateway to program and the cert to issue ---
log_info "Waiting for the Gateway to be Programmed..."
kubectl wait gateway frontend-gateway -n online-boutique --for=condition=Programmed --timeout=120s \
  || log_warn "Gateway not Programmed yet — check: kubectl describe gateway frontend-gateway -n online-boutique"

log_info "Waiting for the certificate to be issued (can take a few minutes for ACME)..."
kubectl wait certificate frontend-tls -n online-boutique --for=condition=Ready --timeout=300s \
  || log_warn "Certificate not Ready yet — check: kubectl describe certificate frontend-tls -n online-boutique; kubectl describe challenge -n online-boutique"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/04-networking-gateway/scripts/verify.sh"
echo "  Then browse: https://${APP_DOMAIN}"
echo "============================================================"
echo ""
