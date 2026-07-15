#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — enable-multicluster.sh (Module 14 equivalent)
#
# Installs Rancher on the primary AKS cluster — Rancher itself has zero
# CNI-specific logic (it just needs cert-manager present, already true
# from enable-networking.sh); the only thing that actually differs from
# Module 14's own rancher-values.yaml is gatewayClass.name. Importing a
# second cluster is a manual Rancher-UI step here too, same as the native
# track, once you have a second AKS cluster (see platforms/aks/terraform/
# — same module, terraform workspace new cluster2, a second tfvars).
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

RANCHER_CHART_VERSION="${RANCHER_CHART_VERSION:-2.14.3}"
RANCHER_DOMAIN="${RANCHER_DOMAIN:-}"

require_command kubectl
require_command helm
require_cluster
kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1 \
  || die "cert-manager not found. Run enable-networking.sh first."
kubectl get gatewayclass approuting-istio >/dev/null 2>&1 \
  || die "GatewayClass approuting-istio not found. Run enable-managed-addons.sh first."
if [[ -z "$RANCHER_DOMAIN" || "$RANCHER_DOMAIN" == "rancher.shop.example.com" ]]; then
  die "Set a real RANCHER_DOMAIN in platforms/aks/config/aks.env before running this."
fi

echo ""
echo "================================================================"
echo "  AKS Platform Track — Multi-Cluster (Module 14 equivalent)"
echo "================================================================"
echo ""

log_info "Installing Rancher v${RANCHER_CHART_VERSION} (rancher-values.yaml matches Module 14's, gatewayClass swapped to approuting-istio)..."
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest >/dev/null 2>&1 || true
helm repo update rancher-latest >/dev/null
helm upgrade --install rancher rancher-latest/rancher \
  --version "${RANCHER_CHART_VERSION}" \
  --namespace cattle-system --create-namespace \
  -f "${PLATFORM_DIR}/manifests/rancher-values.yaml" \
  --set hostname="${RANCHER_DOMAIN}" \
  --wait --timeout 5m
log_ok "Rancher ready"

log_info "Waiting for the bootstrap password..."
for _ in $(seq 1 20); do
  kubectl get secret bootstrap-secret -n cattle-system >/dev/null 2>&1 && break
  sleep 5
done
BOOTSTRAP_PASSWORD=$(kubectl get secret bootstrap-secret -n cattle-system -o jsonpath='{.data.bootstrapPassword}' 2>/dev/null | base64 -d)

echo ""
echo "================================================================"
echo "  Rancher:            https://${RANCHER_DOMAIN}"
echo "  Bootstrap password:  ${BOOTSTRAP_PASSWORD:-<not found — see: kubectl get secret bootstrap-secret -n cattle-system>}"
echo "  (you'll be asked to set a real admin password on first login)"
echo ""
echo "  Next (manual, same as Module 14):"
echo "  1. Provision a second AKS cluster: cd platforms/aks/terraform &&"
echo "     terraform workspace new cluster2, apply with a different"
echo "     cluster_name/resource_group_name."
echo "  2. In the Rancher UI: Clusters -> Import Existing -> Generic ->"
echo "     copy the kubectl apply command it shows."
echo "  3. az aks get-credentials --resource-group \$SECOND_AKS_RESOURCE_GROUP"
echo "     --name \$SECOND_AKS_CLUSTER_NAME --file platforms/aks/kubeconfig-cluster2.yaml"
echo "  4. KUBECONFIG=platforms/aks/kubeconfig-cluster2.yaml <paste the import command>"
echo "  5. Then: bash platforms/aks/scripts/promote-canary.sh"
echo "================================================================"
echo ""
