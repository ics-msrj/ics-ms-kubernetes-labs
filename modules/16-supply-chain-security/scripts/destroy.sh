#!/bin/bash
# =============================================================================
# Module 16 — Supply Chain Security — destroy.sh
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
echo "  Module 16 — Supply Chain Security — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes the supply-chain-demo namespace, the image-verification"
log_warn "policy, and Trivy Operator. Kyverno itself (Module 06) and its other"
log_warn "policies are untouched."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

pkill -f "port-forward.*supply-chain-demo.*5000" 2>/dev/null || true
kubectl delete clusterpolicy verify-signed-images-supply-chain-demo --ignore-not-found=true
kubectl delete namespace supply-chain-demo --ignore-not-found=true
log_ok "Policy and supply-chain-demo namespace removed"

if kubectl get namespace trivy-system &>/dev/null; then
  helm uninstall trivy-operator -n trivy-system &>/dev/null || true
  kubectl delete namespace trivy-system --ignore-not-found=true
  log_ok "Trivy Operator removed"
fi

if [ -d "${MODULE_DIR}/generated" ]; then
  rm -rf "${MODULE_DIR}/generated"
  log_ok "Local generated/ (SBOM, cosign keypair) removed"
fi

echo ""
echo "================================================================"
echo "  Module 16 cleanup complete."
echo "================================================================"
echo ""
