#!/bin/bash
# =============================================================================
# Module 09 — Logging — destroy.sh
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
echo "  Module 09 — Logging — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes Alloy, Loki (and all stored logs — Loki's PVC is deleted), and the Grafana datasource."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete -f "${MODULE_DIR}/manifests/grafana-loki-datasource.yaml" --ignore-not-found=true
log_ok "Grafana datasource removed"

if kubectl get daemonset alloy -n monitoring &>/dev/null; then
  helm uninstall alloy -n monitoring
  log_ok "Alloy removed"
fi

if kubectl get statefulset loki -n monitoring &>/dev/null; then
  helm uninstall loki -n monitoring
  kubectl delete pvc -n monitoring -l app.kubernetes.io/name=loki --ignore-not-found=true
  log_ok "Loki and its PVC removed"
fi

echo ""
echo "================================================================"
echo "  Module 09 cleanup complete."
echo "================================================================"
echo ""
