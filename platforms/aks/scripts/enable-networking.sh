#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — enable-networking.sh
#
# The AKS equivalent of Module 04. Reuses Module 04's own manifests
# wherever they have no CNI-specific assumption (ClusterIssuers, the
# frontend HTTPRoute, the redis-cart NetworkPolicy — all plain
# cert-manager/Gateway API/NetworkPolicy objects, portable as-is) and
# replaces only what's genuinely different: no Cilium-enable step (AKS's
# application-routing add-on IS the Gateway implementation, already
# turned on by enable-managed-addons.sh), and a Gateway manifest whose
# only difference from Module 04's is gatewayClassName.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/04-networking-gateway"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-1.6.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.21.0}"

APP_DOMAIN="${APP_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"

require_command kubectl
require_command helm
require_cluster
kubectl get namespace online-boutique >/dev/null || die "Namespace online-boutique not found. Run deploy-core-workloads first."
if [[ -z "$APP_DOMAIN" || "$APP_DOMAIN" == "shop.example.com" ]]; then
  die "Set a real APP_DOMAIN in platforms/aks/config/aks.env before running this."
fi
if [[ "$TLS_ISSUER" != "selfsigned" && -z "$ACME_EMAIL" ]]; then
  die "TLS_ISSUER=${TLS_ISSUER} needs ACME_EMAIL set in aks.env, or set TLS_ISSUER=selfsigned."
fi
kubectl get gatewayclass approuting-istio >/dev/null 2>&1 \
  || die "GatewayClass approuting-istio not found. Run enable-managed-addons.sh and wait for it to finish first."

echo ""
echo "================================================================"
echo "  AKS Platform Track — Networking (Module 04 equivalent)"
echo "  Domain: ${APP_DOMAIN}   TLS issuer: ${TLS_ISSUER}"
echo "================================================================"
echo ""

log_info "Installing Gateway API CRDs v${GATEWAY_API_VERSION} (idempotent if App Routing already installed them)..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/standard-install.yaml"

log_info "Installing cert-manager v${CERT_MANAGER_VERSION} (same as Module 04, no AKS-specific change)..."
if kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
  log_info "cert-manager already installed — skipping"
else
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null
  helm install cert-manager jetstack/cert-manager \
    --version "v${CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace
fi
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=120s
log_ok "cert-manager ready"

log_info "Applying ClusterIssuers (reused unmodified from Module 04)..."
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/clusterissuer-selfsigned.yaml"
if [[ -n "$ACME_EMAIL" ]]; then
  sed "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "${NATIVE_MODULE_DIR}/manifests/clusterissuer-letsencrypt-staging.yaml" | kubectl apply -f -
  sed "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "${NATIVE_MODULE_DIR}/manifests/clusterissuer-letsencrypt-production.yaml" | kubectl apply -f -
fi
log_ok "ClusterIssuers applied"

log_info "Applying Gateway (approuting-istio, issuer: ${TLS_ISSUER}) and HTTPRoute (host: ${APP_DOMAIN})..."
sed "s|__TLS_ISSUER__|${TLS_ISSUER}|g" "${PLATFORM_DIR}/manifests/gateway.yaml" | kubectl apply -f -
sed "s|__APP_DOMAIN__|${APP_DOMAIN}|g" "${NATIVE_MODULE_DIR}/manifests/httproute-frontend.yaml" | kubectl apply -f -
log_ok "Gateway and HTTPRoute applied"

log_info "Locking down redis-cart to cartservice only (reused unmodified from Module 04)..."
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/networkpolicy-redis-cart.yaml"
log_ok "NetworkPolicy applied"

log_info "Waiting for the Gateway to be Programmed..."
kubectl wait gateway frontend-gateway -n online-boutique --for=condition=Programmed --timeout=120s \
  || log_warn "Gateway not Programmed yet — check: kubectl describe gateway frontend-gateway -n online-boutique"

log_info "Waiting for the certificate to be issued (can take a few minutes for ACME)..."
kubectl wait certificate frontend-tls -n online-boutique --for=condition=Ready --timeout=300s \
  || log_warn "Certificate not Ready yet — check: kubectl describe certificate frontend-tls -n online-boutique"

echo ""
echo "================================================================"
echo "  Networking ready. Browse: https://${APP_DOMAIN}"
echo "================================================================"
echo ""
