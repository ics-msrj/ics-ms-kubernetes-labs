#!/bin/bash
# =============================================================================
# Module 18 — Chaos Engineering & Incident Response — destroy.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "================================================================"
echo "  Module 18 — Chaos Engineering — Cleanup"
echo "================================================================"
echo ""
log_warn "This deletes any chaos experiments still applied to online-boutique,"
log_warn "then uninstalls Chaos Mesh entirely (control plane, chaos-daemon,"
log_warn "dashboard, CRDs, chaos-mesh namespace)."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

log_info "Removing any leftover chaos experiments..."
kubectl delete podchaos,networkchaos,stresschaos,workflow -n online-boutique --all --ignore-not-found=true &>/dev/null || true
log_ok "online-boutique is clean of chaos objects"

if kubectl get namespace chaos-mesh &>/dev/null; then
  log_info "Uninstalling Chaos Mesh..."
  helm uninstall chaos-mesh -n chaos-mesh &>/dev/null || true
  kubectl delete namespace chaos-mesh --ignore-not-found=true
  # Helm never deletes CRDs on uninstall (avoids destroying user data on a
  # routine upgrade) — remove Chaos Mesh's cluster-scoped CRDs explicitly
  # since this is a full module teardown, not an upgrade.
  kubectl get crd -o name | grep 'chaos-mesh.org' | xargs -r kubectl delete
  log_ok "Chaos Mesh removed"
else
  log_warn "chaos-mesh namespace not found — already removed"
fi

echo ""
echo "================================================================"
echo "  Module 18 cleanup complete."
echo "================================================================"
echo ""
