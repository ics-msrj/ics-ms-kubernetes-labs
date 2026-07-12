#!/bin/bash
# =============================================================================
# Module 14 — Multi-Cluster Management — destroy.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "================================================================"
echo "  Module 14 — Multi-Cluster Management — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes Rancher from the primary cluster and the local kubeconfig"
log_warn "for the second cluster. The second cluster's VMs keep running and stay"
log_warn "kubeadm-joined — reset them yourself (kubeadm reset -f on each, same as"
log_warn "Module 01's destroy.sh does for the primary cluster) or leave them for a re-import."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete -f "${MODULE_DIR}/manifests/canary-app.yaml" --ignore-not-found=true &>/dev/null || true
if [[ -f "${MODULE_DIR}/kubeconfig-cluster2.yaml" ]]; then
  KUBECONFIG="${MODULE_DIR}/kubeconfig-cluster2.yaml" kubectl delete -f "${MODULE_DIR}/manifests/canary-app.yaml" --ignore-not-found=true &>/dev/null || true
fi
log_ok "canary-demo removed from both clusters (if it was present)"

if kubectl get namespace cattle-system &>/dev/null; then
  helm uninstall rancher -n cattle-system &>/dev/null || true
  kubectl delete namespace cattle-system --ignore-not-found=true
  log_ok "Rancher removed"
fi

pkill -f "ssh.*6444:" 2>/dev/null && log_info "Killed the second cluster's SSH tunnel" || true
rm -f "${MODULE_DIR}/kubeconfig-cluster2.yaml"
log_ok "Local second-cluster kubeconfig removed"

echo ""
echo "================================================================"
echo "  Module 14 cleanup complete."
echo "================================================================"
echo ""
