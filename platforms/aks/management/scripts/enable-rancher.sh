#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command helm
require_config
require_cluster
require_rancher_config

kubectl get deployment cloudflared -n cloudflare-tunnel >/dev/null 2>&1 \
  || die "Cloudflare Tunnel connector is not installed. Run enable-cloudflare first."

echo ""
echo "================================================================"
echo "  Rancher Management Cluster - Install Rancher"
echo "================================================================"
echo ""

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null

if ! kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
  log_info "Installing cert-manager v${AKS_MANAGEMENT_CERT_MANAGER_VERSION}..."
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${AKS_MANAGEMENT_CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
  helm upgrade --install cert-manager jetstack/cert-manager \
    --version "v${AKS_MANAGEMENT_CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace \
    --wait --timeout 10m
fi

for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
  kubectl rollout status "deployment/${deployment}" -n cert-manager --timeout=300s
done
log_ok "cert-manager is ready"

log_info "Installing Rancher ${AKS_MANAGEMENT_RANCHER_CHART_VERSION} with ${AKS_MANAGEMENT_RANCHER_REPLICAS} replica(s)..."
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable >/dev/null 2>&1 || true
helm repo update rancher-stable >/dev/null
helm upgrade --install rancher rancher-stable/rancher \
  --version "${AKS_MANAGEMENT_RANCHER_CHART_VERSION}" \
  --namespace cattle-system --create-namespace \
  --set hostname="${AKS_MANAGEMENT_RANCHER_HOSTNAME}" \
  --set replicas="${AKS_MANAGEMENT_RANCHER_REPLICAS}" \
  -f "${MANAGEMENT_DIR}/manifests/rancher/values.yaml" \
  --wait --timeout 10m

kubectl rollout status deployment/rancher -n cattle-system --timeout=600s
log_ok "Rancher is ready inside the management cluster."

echo ""
echo "Configure this Cloudflare public hostname in Zero Trust:"
echo "  https://${AKS_MANAGEMENT_RANCHER_HOSTNAME} -> http://rancher.cattle-system.svc.cluster.local:80"
echo ""
echo "Retrieve the one-time bootstrap password locally:"
echo "  kubectl get secret bootstrap-secret -n cattle-system -o jsonpath='{.data.bootstrapPassword}' | base64 -d; echo"
echo ""
echo "Then open Rancher, set the admin password, and import each downstream through"
echo "Cluster Management -> Import Existing -> Generic. Do not apply a generated"
echo "import manifest to this management cluster."
