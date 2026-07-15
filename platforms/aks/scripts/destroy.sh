#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — destroy.sh
#
# Removes what deploy-core-workloads.sh created (the online-boutique
# namespace and everything in it). Matches this track's own stated
# boundary: never touches the managed control plane, node pools, or the
# add-ons enable-managed-addons.sh turned on — those are Azure-billed
# resources this track doesn't own and won't silently disable.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command helm
require_cluster

echo ""
echo "================================================================"
echo "  AKS Platform Track — Cleanup"
echo "================================================================"
echo ""
log_warn "This deletes the online-boutique namespace, the velero namespace"
log_warn "(MinIO/Velero), and Rancher (if installed) from AKS cluster"
log_warn "${AKS_CLUSTER_NAME:-<unset>}. The AKS cluster, its node pools, and"
log_warn "enable-managed-addons.sh's VPA/KEDA/App Routing settings are NOT"
log_warn "touched — disable those yourself via 'az aks update' if you no"
log_warn "longer want them."
echo ""
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

kubectl delete namespace online-boutique --ignore-not-found=true
log_ok "online-boutique namespace removed from AKS."

if kubectl get namespace velero >/dev/null 2>&1; then
  helm uninstall velero -n velero >/dev/null 2>&1 || true
  helm uninstall minio -n velero >/dev/null 2>&1 || true
  kubectl delete namespace velero --ignore-not-found=true
  log_ok "velero namespace (MinIO/Velero) removed."
fi

if kubectl get namespace cattle-system >/dev/null 2>&1; then
  helm uninstall rancher -n cattle-system >/dev/null 2>&1 || true
  kubectl delete namespace cattle-system --ignore-not-found=true
  log_ok "Rancher removed."
fi
