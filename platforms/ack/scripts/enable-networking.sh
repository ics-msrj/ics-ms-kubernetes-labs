#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/04-networking-gateway"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.21.0}"
APP_DOMAIN="${APP_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"

require_command kubectl
require_command helm
require_cluster
kubectl get namespace online-boutique >/dev/null || die "Run deploy-core-workloads first."
[[ -n "${APP_DOMAIN}" && "${APP_DOMAIN}" != "shop.example.com" ]] \
  || die "Set APP_DOMAIN in platforms/ack/config/ack.env."
if [[ "${TLS_ISSUER}" != "selfsigned" && -z "${ACME_EMAIL}" ]]; then
  die "Set ACME_EMAIL or use TLS_ISSUER=selfsigned for a non-public test."
fi

# ACK ALB Gateway API support is supplied by ALB Ingress Controller v2.17+.
# Its console installation creates GatewayClass/alb after selecting two
# ALB-capable vSwitches in distinct zones; a Gateway can incur ALB charges.
kubectl get gatewayclass alb >/dev/null 2>&1 || die "GatewayClass alb is absent. In ACK Console install ALB Ingress Controller v2.17+ with two ALB-capable vSwitches, then retry."

if ! kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null
  helm install cert-manager jetstack/cert-manager --version "v${CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace --set config.gatewayAPI.enabled=true
fi
for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
  kubectl rollout status "deployment/${deployment}" -n cert-manager --timeout=180s
done
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/clusterissuer-selfsigned.yaml"
if [[ -n "${ACME_EMAIL}" ]]; then
  sed "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "${NATIVE_MODULE_DIR}/manifests/clusterissuer-letsencrypt-staging.yaml" | kubectl apply -f -
  sed "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "${NATIVE_MODULE_DIR}/manifests/clusterissuer-letsencrypt-production.yaml" | kubectl apply -f -
fi
sed -e "s|__TLS_ISSUER__|${TLS_ISSUER}|g" -e "s|__APP_DOMAIN__|${APP_DOMAIN}|g" \
  "${PLATFORM_DIR}/manifests/gateway.yaml" | kubectl apply -f -
sed "s|__APP_DOMAIN__|${APP_DOMAIN}|g" "${NATIVE_MODULE_DIR}/manifests/httproute-frontend.yaml" | kubectl apply -f -
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/networkpolicy-redis-cart.yaml"
kubectl wait gateway frontend-gateway -n online-boutique --for=condition=Programmed --timeout=600s \
  || log_warn "Gateway is not programmed yet; inspect it before changing DNS."
log_ok "Module 04 equivalent applied. A Gateway-created ALB remains billable until the Gateway is deleted."
