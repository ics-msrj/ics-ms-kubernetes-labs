#!/bin/bash
# =============================================================================
# Module 18 — Chaos Engineering & Incident Response — setup.sh
#
# Installs Chaos Mesh (control plane + per-node chaos-daemon + dashboard)
# ONLY. It does not run any experiment — every GameDay scenario in this
# module is a real, disruptive fault against the online-boutique namespace
# and is applied by hand, on purpose, following the README's Lab steps.
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

CHAOS_MESH_CHART_VERSION="${CHAOS_MESH_CHART_VERSION:-2.8.3}"

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

echo ""
echo "============================================================"
echo "  Module 18 — Chaos Engineering — Setup"
echo "============================================================"
echo ""

log_info "Installing Chaos Mesh v${CHAOS_MESH_CHART_VERSION} (containerd runtime)..."
helm repo add chaos-mesh https://charts.chaos-mesh.org &>/dev/null || true
helm repo update chaos-mesh &>/dev/null
kubectl create namespace chaos-mesh --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --version "${CHAOS_MESH_CHART_VERSION}" \
  --namespace chaos-mesh \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.create=true \
  --wait --timeout 5m
log_ok "Chaos Mesh control plane, chaos-daemon DaemonSet, and dashboard ready"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/18-chaos-engineering/scripts/verify.sh"
echo ""
echo "  Dashboard:"
echo "    kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333"
echo "    then open http://localhost:2333"
echo ""
DASHBOARD_SA=$(kubectl get sa -n chaos-mesh -o name 2>/dev/null | grep -i "account-cluster-manager" | head -1 | cut -d/ -f2 || true)
if [[ -n "$DASHBOARD_SA" ]]; then
  echo "  Login token:"
  echo "    kubectl create token -n chaos-mesh ${DASHBOARD_SA}"
else
  log_warn "Could not auto-detect the dashboard ServiceAccount — list them with:"
  echo "    kubectl get sa -n chaos-mesh"
fi
echo ""
echo "  No experiments have been applied yet — see this module's README"
echo "  'Lab' section for the 6 GameDay scenarios, applied one at a time."
echo "============================================================"
echo ""
