#!/bin/bash
# =============================================================================
# Module 02 — Core Workloads — destroy.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "================================================================"
echo "  Module 02 — Core Workloads — Cleanup"
echo "================================================================"
echo ""
log_warn "This deletes the entire 'online-boutique' namespace — every"
log_warn "Deployment, the redis-cart StatefulSet, and its PersistentVolumeClaim"
log_warn "(cart data is not recoverable after this)."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

if kubectl get namespace online-boutique &>/dev/null; then
  kubectl delete namespace online-boutique --wait=true --timeout=120s
  log_ok "Namespace online-boutique deleted"
else
  log_info "Namespace online-boutique already gone — nothing to do"
fi

echo ""
log_info "local-path-provisioner (namespace local-path-storage) was left running —"
log_info "later modules and re-runs of this one depend on it. Remove it manually if needed:"
log_info "  kubectl delete -f modules/02-core-workloads/manifests/local-path-provisioner.yaml"
echo ""
echo "================================================================"
echo "  Module 02 cleanup complete."
echo "================================================================"
echo ""
