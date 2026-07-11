#!/bin/bash
# =============================================================================
# Module 10 — Package Management — destroy.sh
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
echo "  Module 10 — Package Management — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes the online-boutique-packaged and online-boutique-dev"
log_warn "namespaces entirely. The online-boutique namespace (Modules 02-09) is untouched."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

if kubectl get namespace online-boutique-packaged &>/dev/null; then
  helm uninstall online-boutique -n online-boutique-packaged
  kubectl delete namespace online-boutique-packaged --ignore-not-found=true
  log_ok "online-boutique-packaged removed"
fi

kubectl delete namespace online-boutique-dev --ignore-not-found=true
log_ok "online-boutique-dev removed"

if [ -d "${MODULE_DIR}/generated" ]; then
  rm -rf "${MODULE_DIR}/generated"
fi

echo ""
echo "================================================================"
echo "  Module 10 cleanup complete."
echo "================================================================"
echo ""
