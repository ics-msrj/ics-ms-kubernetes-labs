#!/bin/bash
# =============================================================================
# Module 11 — GitOps & CI/CD — destroy.sh
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
echo "  Module 11 — GitOps & CI/CD — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes ArgoCD and its Applications. The Applications' own"
log_warn "finalizers are NOT set to cascade-delete, so online-boutique-packaged"
log_warn "and online-boutique-dev keep running — just no longer GitOps-managed"
log_warn "(back to how Module 10 left them: plain helm/kustomize state)."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete application root-app online-boutique-packaged online-boutique-dev -n argocd --ignore-not-found=true
kubectl delete httproute argocd -n argocd --ignore-not-found=true
log_ok "Applications and HTTPRoute removed"

if kubectl get namespace argocd &>/dev/null; then
  helm uninstall argocd -n argocd
  kubectl delete namespace argocd --ignore-not-found=true
  log_ok "ArgoCD removed"
fi

echo ""
log_info "Reverting the Gateway to drop the argocd listener needs Module 08's"
log_info "setup.sh re-run (it owns the next-most-recent full listener set)."
echo ""
echo "================================================================"
echo "  Module 11 cleanup complete."
echo "================================================================"
echo ""
