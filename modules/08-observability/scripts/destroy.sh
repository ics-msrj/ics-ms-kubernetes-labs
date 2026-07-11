#!/bin/bash
# =============================================================================
# Module 08 — Observability — destroy.sh
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
echo "  Module 08 — Observability — Cleanup"
echo "================================================================"
echo ""
log_warn "This uninstalls kube-prometheus-stack entirely and removes the"
log_warn "Grafana Gateway listener/HTTPRoute. cert-manager's ServiceMonitor"
log_warn "setting is left as-is (harmless without Prometheus running)."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete httproute grafana -n monitoring --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/podmonitor-node-exporter.yaml" --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/prometheusrule-alerts.yaml" --ignore-not-found=true
log_ok "PodMonitor, PrometheusRule, and HTTPRoute removed"

log_info "Reverting the Gateway to Module 04's listeners (dropping https-grafana)..."
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"
sed "s|__TLS_ISSUER__|${TLS_ISSUER:-selfsigned}|g" \
  "${SCRIPT_DIR}/../../04-networking-gateway/manifests/gateway.yaml" | kubectl apply -f - \
  || log_warn "Gateway revert failed — re-run Module 04's setup.sh to restore its listeners."

if kubectl get namespace monitoring &>/dev/null; then
  helm uninstall monitoring -n monitoring
  kubectl delete namespace monitoring --ignore-not-found=true
  log_ok "kube-prometheus-stack removed"
fi

if [ -d "${MODULE_DIR}/generated" ]; then
  rm -rf "${MODULE_DIR}/generated"
fi

echo ""
echo "================================================================"
echo "  Module 08 cleanup complete."
echo "================================================================"
echo ""
