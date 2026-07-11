#!/bin/bash
# =============================================================================
# Module 07 — Scalability & HA — destroy.sh
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
echo "  Module 07 — Scalability & HA — Cleanup"
echo "================================================================"
echo ""
log_warn "This removes HPA/VPA/ScaledObject/PDB objects and uninstalls"
log_warn "metrics-server, VPA, and KEDA entirely."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

kubectl delete -f "${MODULE_DIR}/manifests/hpa-frontend.yaml" --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/vpa-productcatalogservice.yaml" --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/keda-scaledobject-loadgenerator.yaml" --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/pdb-frontend.yaml" --ignore-not-found=true
kubectl delete -f "${MODULE_DIR}/manifests/pdb-cartservice.yaml" --ignore-not-found=true
log_ok "HPA, VPA, ScaledObject, and PDBs removed"

if kubectl get namespace keda &>/dev/null; then
  helm uninstall keda -n keda
  kubectl delete namespace keda --ignore-not-found=true
  log_ok "KEDA removed"
fi
if kubectl get deployment vpa-vertical-pod-autoscaler-recommender -n kube-system &>/dev/null; then
  helm uninstall vpa -n kube-system
  log_ok "VPA removed"
fi
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  helm uninstall metrics-server -n kube-system
  log_ok "metrics-server removed"
fi

kubectl scale deployment cartservice -n online-boutique --replicas=1 &>/dev/null || true

echo ""
echo "================================================================"
echo "  Module 07 cleanup complete."
echo "================================================================"
echo ""
