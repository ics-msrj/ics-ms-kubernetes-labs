#!/bin/bash
# =============================================================================
# Module 04 — Networking & Gateway API — destroy.sh
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
echo "  Module 04 — Networking & Gateway API — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes the Gateway, HTTPRoute, ClusterIssuers, cert-manager,"
log_warn "and the redis-cart NetworkPolicy. frontend becomes unreachable"
log_warn "except via kubectl port-forward until you re-run setup.sh."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete networkpolicy redis-cart-allow-cartservice-only -n online-boutique --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/bonus/networkpolicy-default-deny-ingress.yaml" --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/bonus/ciliumnetworkpolicy-loadgenerator-l7.yaml" --ignore-not-found=true
kubectl delete httproute frontend -n online-boutique --ignore-not-found=true
kubectl delete gateway frontend-gateway -n online-boutique --ignore-not-found=true
kubectl delete clusterissuer selfsigned letsencrypt-staging letsencrypt-production --ignore-not-found=true
log_ok "Gateway, HTTPRoute, NetworkPolicies, and ClusterIssuers removed"

if kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
  helm uninstall cert-manager -n cert-manager
  kubectl delete namespace cert-manager --ignore-not-found=true
  log_ok "cert-manager removed"
fi

echo ""
log_info "Cilium's Gateway API support (Helm values) and the Gateway API CRDs"
log_info "were left in place — shared cluster-wide state, harmless to leave."
echo ""
echo "================================================================"
echo "  Module 04 cleanup complete."
echo "================================================================"
echo ""
