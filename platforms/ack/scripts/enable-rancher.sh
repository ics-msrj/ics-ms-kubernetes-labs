#!/usr/bin/env bash
# Installs Rancher as the ACK-hosted management server for Module 14.

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
  || die "Cloudflare Tunnel connector is not installed. Run enable-cf-tunnel first."
kubectl get clusterpolicy require-resource-limits >/dev/null 2>&1 \
  || die "Kyverno resource policy is missing. Complete Module 06 first."

echo ""
echo "================================================================"
echo "  ACK Platform Track - Rancher Management Server (Module 14)"
echo "================================================================"
echo ""

log_info "Installing Rancher ${ACK_RANCHER_CHART_VERSION} with ${ACK_RANCHER_REPLICAS} replica(s)..."
# Rancher's upstream pre-upgrade hook has no resource override. Reapply the
# source policy so its narrow cattle-system exception is present before Helm
# creates that hook on a subsequent upgrade.
kubectl apply -f "${REPO_ROOT}/modules/06-security-policy/manifests/kyverno-policy-require-resource-limits.yaml" >/dev/null
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest >/dev/null 2>&1 || true
helm repo update rancher-latest >/dev/null
helm upgrade --install rancher rancher-latest/rancher \
  --version "${ACK_RANCHER_CHART_VERSION}" \
  --namespace cattle-system --create-namespace \
  --set hostname="${ACK_RANCHER_HOSTNAME}" \
  --set replicas="${ACK_RANCHER_REPLICAS}" \
  -f "${PLATFORM_DIR}/manifests/rancher-values.yaml" \
  --wait --timeout 10m

kubectl rollout status deployment/rancher -n cattle-system --timeout=600s
log_ok "Rancher is ready inside ACK."

echo ""
echo "Configure this Cloudflare Tunnel public hostname in Zero Trust:"
echo "  https://${ACK_RANCHER_HOSTNAME} -> http://rancher.cattle-system.svc.cluster.local:80"
echo ""
echo "Retrieve the one-time bootstrap password locally:"
echo "  kubectl get secret bootstrap-secret -n cattle-system -o jsonpath='{.data.bootstrapPassword}' | base64 -d; echo"
echo ""
echo "Then open Rancher, import AKS and GKE through Cluster Management -> Import Existing -> Generic,"
echo "and run: bash platforms/ack/scripts/ack-track.sh verify-rancher"
