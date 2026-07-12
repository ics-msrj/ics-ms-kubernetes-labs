#!/bin/bash
# =============================================================================
# Module 15 — Multi-Tenancy & Cost — setup.sh
#
# 1. Applies ResourceQuota + LimitRange to online-boutique and
#    online-boutique-packaged, treating them as two separate tenants
# 2. Installs OpenCost, pointed at Module 08's existing Prometheus (no
#    second Prometheus, no bundled Grafana)
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"

OPENCOST_CHART_VERSION="${OPENCOST_CHART_VERSION:-2.5.26}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get namespace online-boutique &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Namespace online-boutique not found. Complete Module 02 first." >&2
  exit 1
fi
if ! kubectl get deployment monitoring-kube-prometheus-operator -n monitoring &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Prometheus not found. Complete Module 08 first." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 15 — Multi-Tenancy & Cost — Setup"
echo "============================================================"
echo ""

# --- Step 1: ResourceQuota + LimitRange ---
log_info "Applying ResourceQuota + LimitRange to online-boutique..."
kubectl apply -f "${MODULE_DIR}/manifests/resourcequota-online-boutique.yaml"
kubectl apply -f "${MODULE_DIR}/manifests/limitrange-online-boutique.yaml"

if kubectl get namespace online-boutique-packaged &>/dev/null; then
  log_info "Applying ResourceQuota + LimitRange to online-boutique-packaged..."
  kubectl apply -f "${MODULE_DIR}/manifests/resourcequota-online-boutique-packaged.yaml"
  kubectl apply -f "${MODULE_DIR}/manifests/limitrange-online-boutique-packaged.yaml"
else
  log_warn "online-boutique-packaged not found (Module 10 not run?) — applying quota to online-boutique only"
fi
log_ok "Quotas and limits applied"

# --- Step 2: OpenCost ---
log_info "Installing OpenCost v${OPENCOST_CHART_VERSION}..."
helm repo add opencost https://opencost.github.io/opencost-helm-chart &>/dev/null || true
helm repo update opencost &>/dev/null
helm upgrade --install opencost opencost/opencost \
  --version "${OPENCOST_CHART_VERSION}" \
  --namespace opencost --create-namespace \
  -f "${MODULE_DIR}/manifests/opencost-values.yaml" \
  --wait --timeout 5m
log_ok "OpenCost ready"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/15-multi-tenancy-cost/scripts/verify.sh"
echo ""
echo "  OpenCost UI: kubectl port-forward -n opencost svc/opencost 9090:9090"
echo "               then open http://localhost:9090"
echo "============================================================"
echo ""
