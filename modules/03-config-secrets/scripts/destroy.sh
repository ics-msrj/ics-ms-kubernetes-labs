#!/bin/bash
# =============================================================================
# Module 03 — Config & Secrets — destroy.sh
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
echo "  Module 03 — Config & Secrets — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes the ConfigMap, the Secret/SealedSecret, and the Sealed"
log_warn "Secrets controller. cartservice and the 6 ConfigMap-consuming"
log_warn "Deployments will start failing on their next restart until you"
log_warn "re-run Module 02 and Module 03 setup.sh."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete secret redis-cart-credentials -n online-boutique --ignore-not-found=true
kubectl delete sealedsecret redis-cart-credentials -n online-boutique --ignore-not-found=true
kubectl delete configmap online-boutique-shared-config -n online-boutique --ignore-not-found=true
log_ok "Secret/SealedSecret and ConfigMap removed"

kubectl delete -f "${MODULE_DIR}/manifests/sealed-secrets-controller.yaml" --ignore-not-found=true
log_ok "Sealed Secrets controller removed"

if [ -d "${MODULE_DIR}/generated" ]; then
  rm -rf "${MODULE_DIR}/generated"
  log_ok "Removed local generated/ artifacts"
fi

echo ""
echo "================================================================"
echo "  Module 03 cleanup complete."
echo "  Re-run: bash modules/02-core-workloads/scripts/setup.sh && bash modules/03-config-secrets/scripts/setup.sh"
echo "================================================================"
echo ""
