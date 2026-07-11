#!/bin/bash
# =============================================================================
# Module 12 — Progressive Delivery — destroy.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "================================================================"
echo "  Module 12 — Progressive Delivery — Cleanup"
echo "================================================================"
echo ""
log_warn "This deletes the frontend and productcatalogservice Rollouts (and"
log_warn "their pods) and uninstalls Argo Rollouts. Neither service will have"
log_warn "any workload running until you re-run Module 02 and Module 03"
log_warn "setup.sh to restore them as plain Deployments."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete rollout frontend productcatalogservice -n online-boutique --ignore-not-found=true
kubectl delete hpa frontend -n online-boutique --ignore-not-found=true
kubectl delete analysistemplate frontend-no-restarts -n online-boutique --ignore-not-found=true
kubectl delete svc productcatalogservice-preview -n online-boutique --ignore-not-found=true
log_ok "Rollouts, HPA, AnalysisTemplate, and preview Service removed"

if kubectl get namespace argo-rollouts &>/dev/null; then
  helm uninstall argo-rollouts -n argo-rollouts
  kubectl delete namespace argo-rollouts --ignore-not-found=true
  log_ok "Argo Rollouts controller removed"
fi

echo ""
echo "================================================================"
echo "  Module 12 cleanup complete."
echo "  Restore plain Deployments: bash modules/02-core-workloads/scripts/setup.sh && bash modules/03-config-secrets/scripts/setup.sh && bash modules/07-scalability-ha/scripts/setup.sh"
echo "================================================================"
echo ""
