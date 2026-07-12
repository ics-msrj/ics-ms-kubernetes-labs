#!/bin/bash
# =============================================================================
# Module 17 — Service Mesh — destroy.sh
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
echo "  Module 17 — Service Mesh — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes mTLS/traffic-policy objects, disables sidecar injection,"
log_warn "restarts every online-boutique workload again to REMOVE the sidecars,"
log_warn "and uninstalls Istio, Kiali, and Tempo. frontend/checkoutservice keep"
log_warn "their tracing env vars (harmless once Tempo is gone — the exporter"
log_warn "just fails silently in the background)."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete peerauthentication strict-mtls -n online-boutique --ignore-not-found=true
kubectl delete virtualservice currencyservice -n online-boutique --ignore-not-found=true
kubectl delete destinationrule currencyservice -n online-boutique --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/bonus/virtualservice-currencyservice-fault-injection.yaml" --ignore-not-found=true 2>/dev/null || true
log_ok "mTLS and traffic policy objects removed"

log_info "Removing sidecar injection and restarting workloads..."
kubectl label namespace online-boutique istio-injection- &>/dev/null || true
for dep in currencyservice shippingservice cartservice emailservice paymentservice \
           recommendationservice adservice loadgenerator checkoutservice; do
  kubectl rollout restart "deployment/${dep}" -n online-boutique &>/dev/null || true
done
kubectl rollout restart statefulset/redis-cart -n online-boutique &>/dev/null || true
log_ok "Sidecars removed (pods restarted without injection)"

if kubectl get namespace istio-system &>/dev/null; then
  helm uninstall kiali-server -n istio-system &>/dev/null || true
  helm uninstall istiod -n istio-system &>/dev/null || true
  helm uninstall istio-base -n istio-system &>/dev/null || true
  kubectl delete namespace istio-system --ignore-not-found=true
  log_ok "Istio and Kiali removed"
fi

helm uninstall tempo -n monitoring &>/dev/null || true
kubectl delete configmap grafana-tempo-datasource -n monitoring --ignore-not-found=true
log_ok "Tempo removed"

echo ""
echo "================================================================"
echo "  Module 17 cleanup complete."
echo "================================================================"
echo ""
