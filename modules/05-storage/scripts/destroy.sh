#!/bin/bash
# =============================================================================
# Module 05 — Storage — destroy.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "================================================================"
echo "  Module 05 — Storage — Cleanup"
echo "================================================================"
echo ""
log_warn "This uninstalls Longhorn entirely, including every volume it backs —"
log_warn "redis-cart's data will be lost, and its pod will stay Pending until"
log_warn "you re-run Module 02 (local-path) or Module 05 (longhorn) setup.sh."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete pvc redis-cart-restore-test -n online-boutique --ignore-not-found=true
kubectl delete volumesnapshot redis-cart-snapshot -n online-boutique --ignore-not-found=true
kubectl delete statefulset redis-cart -n online-boutique --ignore-not-found=true
kubectl delete pvc redis-data-redis-cart-0 -n online-boutique --ignore-not-found=true
log_ok "redis-cart, its PVC, and the snapshot removed"

if kubectl get namespace longhorn-system &>/dev/null; then
  helm uninstall longhorn -n longhorn-system
  kubectl delete namespace longhorn-system --ignore-not-found=true
  log_ok "Longhorn removed"
fi

echo ""
log_info "VolumeSnapshot CRDs and snapshot-controller were left in place —"
log_info "shared, cluster-wide, harmless to leave installed."
echo ""
echo "================================================================"
echo "  Module 05 cleanup complete."
echo "  Re-run: bash modules/02-core-workloads/scripts/setup.sh && bash modules/03-config-secrets/scripts/setup.sh"
echo "================================================================"
echo ""
