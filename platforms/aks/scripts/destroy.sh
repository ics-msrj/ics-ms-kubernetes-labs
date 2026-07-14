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
require_cluster

echo ""
echo "================================================================"
echo "  AKS Platform Track — Cleanup"
echo "================================================================"
echo ""
log_warn "This deletes the online-boutique namespace from AKS cluster ${AKS_CLUSTER_NAME:-<unset>}."
log_warn "The AKS cluster, its node pools, and enable-managed-addons.sh's"
log_warn "VPA/KEDA/App Routing settings are NOT touched — disable those"
log_warn "yourself via 'az aks update' if you no longer want them."
echo ""
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

kubectl delete namespace online-boutique --ignore-not-found=true
log_ok "online-boutique namespace removed from AKS."
