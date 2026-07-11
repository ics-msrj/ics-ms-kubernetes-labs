#!/bin/bash
# =============================================================================
# Module 06 — Security Policy — destroy.sh
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
echo "  Module 06 — Security Policy — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes RBAC, Kyverno, and the PSA labels on online-boutique."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete -f "${MODULE_DIR}/manifests/rbac-viewer.yaml" --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/rbac-ci-deployer.yaml" --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/bonus/rbac-overprivileged-example.yaml" --ignore-not-found=true
log_ok "RBAC removed"

kubectl delete -f "${MODULE_DIR}/manifests/kyverno-policy-disallow-latest-tag.yaml" --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/kyverno-policy-require-resource-limits.yaml" --ignore-not-found=true
if kubectl get namespace kyverno &>/dev/null; then
  helm uninstall kyverno -n kyverno
  kubectl delete namespace kyverno --ignore-not-found=true
  log_ok "Kyverno removed"
fi

kubectl label namespace online-boutique \
  pod-security.kubernetes.io/enforce- \
  pod-security.kubernetes.io/enforce-version- \
  pod-security.kubernetes.io/audit- \
  pod-security.kubernetes.io/warn- \
  &>/dev/null
log_ok "PSA labels removed"

echo ""
echo "================================================================"
echo "  Module 06 cleanup complete."
echo "================================================================"
echo ""
