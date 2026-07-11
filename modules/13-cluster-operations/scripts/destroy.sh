#!/bin/bash
# =============================================================================
# Module 13 — Cluster Operations — destroy.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "================================================================"
echo "  Module 13 — Cluster Operations — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes the restore-drill namespace, Velero, and MinIO (and its"
log_warn "stored backups — they only ever lived in-cluster). Local etcd"
log_warn "snapshots in modules/13-cluster-operations/backups/ are left alone."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete namespace online-boutique-restore-drill --ignore-not-found=true
log_ok "online-boutique-restore-drill removed"

if kubectl get namespace velero &>/dev/null; then
  helm uninstall velero -n velero &>/dev/null || true
  helm uninstall minio -n velero &>/dev/null || true
  kubectl delete namespace velero --ignore-not-found=true
  log_ok "Velero and MinIO removed"
fi

kubectl label volumesnapshotclass longhorn velero.io/csi-volumesnapshot-class- &>/dev/null || true

echo ""
echo "================================================================"
echo "  Module 13 cleanup complete."
echo "================================================================"
echo ""
