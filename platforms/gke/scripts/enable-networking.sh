#!/usr/bin/env bash
# =============================================================================
# GKE Platform Track — enable-networking.sh
#
# The GKE equivalent of Module 04. Reuses Module 04's own manifests
# wherever they have no CNI-specific assumption (ClusterIssuers, the
# frontend HTTPRoute, the redis-cart NetworkPolicy — all plain
# cert-manager/Gateway API/NetworkPolicy objects, portable as-is, same
# reasoning as the AKS track's own enable-networking.sh) and replaces
# only what's genuinely different: no Gateway-API-CRD-install step (GKE's
# own Gateway controller installs them itself when the managed add-on is
# enabled), and a Gateway manifest whose only difference from Module 04's
# is gatewayClassName.
#
# Two real issues found running this live against GKE (both fixed, not
# hypothetical):
#   1. GKE's regional external Gateway LB needs a dedicated
#      REGIONAL_MANAGED_PROXY subnet in the same VPC/region — a
#      Terraform-level prerequisite (platforms/gke/terraform/main.tf's
#      google_compute_subnetwork.proxy_only), not something this script
#      can fix at apply time. Without it: "error ensuring load balancer:
#      ... An active proxy-only subnetwork is required...".
#   2. GKE's LB rejects a TLS cert with an empty Subject (SAN-only) —
#      "error cause: ... The SSL certificate could not be parsed." Fixed
#      via the cert-manager.io/common-name annotation on the Gateway
#      (see manifests/gateway.yaml) so the auto-generated Certificate
#      gets a real Subject CN.
#
# Separately, cert-manager's HTTP-01 solver has a documented
# GKE-Gateway-controller integration bug where the solver Pod runs but
# the challenge doesn't propagate through the Gateway correctly (404
# instead of 200) — https://github.com/cert-manager/cert-manager/issues/8591.
# Not hit directly here (TLS_ISSUER=selfsigned was used to prove out the
# Gateway/routing layer first, which sidesteps HTTP-01 entirely), but
# still a real risk if TLS_ISSUER=letsencrypt-staging hangs on the
# certificate step below.
# =============================================================================

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
kubectl get namespace online-boutique >/dev/null || die "Namespace online-boutique not found. Run deploy-core-workloads first."
if [[ -z "$APP_DOMAIN" || "$APP_DOMAIN" == "shop.example.com" ]]; then
  die "Set a real APP_DOMAIN in platforms/gke/config/gke.env before running this."
fi
if [[ "$TLS_ISSUER" != "selfsigned" && -z "$ACME_EMAIL" ]]; then
  die "TLS_ISSUER=${TLS_ISSUER} needs ACME_EMAIL set in gke.env, or set TLS_ISSUER=selfsigned."
fi
kubectl get gatewayclass gke-l7-regional-external-managed >/dev/null 2>&1 \
  || die "GatewayClass gke-l7-regional-external-managed not found. Run enable-managed-addons.sh and wait for it to finish first."

echo ""
echo "================================================================"
echo "  GKE Platform Track — Networking (Module 04 equivalent)"
echo "  Domain: ${APP_DOMAIN}   TLS issuer: ${TLS_ISSUER}"
echo "================================================================"
echo ""

log_info "Installing cert-manager v${CERT_MANAGER_VERSION} (same as Module 04, no GKE-specific change)..."
if kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
  log_info "cert-manager already installed — skipping"
else
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null
  # config.gatewayAPI.enabled=true turns on cert-manager's gateway-shim —
  # without it the controller never watches Gateway resources at all, so
  # the Certificate the Gateway annotation below expects is never created.
  # Same requirement discovered on the AKS track — not GKE-specific.
  helm install cert-manager jetstack/cert-manager \
    --version "v${CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace \
    --set config.gatewayAPI.enabled=true
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

log_info "Applying Gateway (gke-l7-regional-external-managed, issuer: ${TLS_ISSUER}) and HTTPRoute (host: ${APP_DOMAIN})..."
sed -e "s|__TLS_ISSUER__|${TLS_ISSUER}|g" -e "s|__APP_DOMAIN__|${APP_DOMAIN}|g" "${PLATFORM_DIR}/manifests/gateway.yaml" | kubectl apply -f -
sed "s|__APP_DOMAIN__|${APP_DOMAIN}|g" "${NATIVE_MODULE_DIR}/manifests/httproute-frontend.yaml" | kubectl apply -f -
log_ok "Gateway and HTTPRoute applied"

log_info "Locking down redis-cart to cartservice only (reused unmodified from Module 04)..."
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/networkpolicy-redis-cart.yaml"
log_ok "NetworkPolicy applied"

log_info "Waiting for the Gateway to be Programmed (GKE provisions a real GCP Load Balancer here — can take several minutes, slower than AKS's app-routing-istio)..."
kubectl wait gateway frontend-gateway -n online-boutique --for=condition=Programmed --timeout=300s \
  || log_warn "Gateway not Programmed yet — check: kubectl describe gateway frontend-gateway -n online-boutique"

log_info "Waiting for the certificate to be issued (can take a few minutes for ACME; see the KNOWN ISSUE note at the top of this script if it hangs)..."
kubectl wait certificate frontend-tls -n online-boutique --for=condition=Ready --timeout=300s \
  || log_warn "Certificate not Ready yet — check: kubectl describe certificate frontend-tls -n online-boutique"

echo ""
echo "================================================================"
echo "  Networking ready. Browse: https://${APP_DOMAIN}"
echo "  (DNS: point ${APP_DOMAIN} at the Gateway's external IP —"
echo "   kubectl get gateway frontend-gateway -n online-boutique -o "
echo "   jsonpath='{.status.addresses[0].value}')"
echo "================================================================"
echo ""
