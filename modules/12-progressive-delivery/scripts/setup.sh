#!/bin/bash
# =============================================================================
# Module 12 — Progressive Delivery — setup.sh
#
# Targets the original online-boutique namespace (imperative since Module 02,
# never adopted by ArgoCD in Module 11) — deliberately, so this module's
# direct kubectl-driven rollout demos don't fight ArgoCD's selfHeal on the
# namespaces Module 11 does manage.
#
# 1. Installs the Argo Rollouts controller
# 2. Converts frontend: Deployment -> Rollout (canary + Prometheus analysis),
#    retargets its HPA (Module 07) at the Rollout instead of the now-gone Deployment
# 3. Converts productcatalogservice: Deployment -> Rollout (blue-green)
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"

ROLLOUTS_CHART_VERSION="${ROLLOUTS_CHART_VERSION:-2.41.0}"

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
  echo -e "${RED}[ERROR]${NC} Prometheus not found. Complete Module 08 first (the AnalysisTemplate queries it)." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 12 — Progressive Delivery — Setup"
echo "============================================================"
echo ""

# --- Step 1: Argo Rollouts controller ---
log_info "Installing Argo Rollouts v${ROLLOUTS_CHART_VERSION}..."
helm repo add argo https://argoproj.github.io/argo-helm &>/dev/null || true
helm repo update argo &>/dev/null
helm upgrade --install argo-rollouts argo/argo-rollouts \
  --version "${ROLLOUTS_CHART_VERSION}" \
  --namespace argo-rollouts --create-namespace \
  --wait --timeout 3m
log_ok "Argo Rollouts controller ready"

# --- Step 2: frontend -> canary Rollout ---
log_info "Applying the AnalysisTemplate..."
kubectl apply -f "${MODULE_DIR}/manifests/analysistemplate-frontend.yaml"

log_info "Converting frontend from Deployment to Rollout..."
kubectl delete deployment frontend -n online-boutique --ignore-not-found=true
kubectl apply -f "${MODULE_DIR}/manifests/rollout-frontend-canary.yaml"
kubectl apply -f "${MODULE_DIR}/manifests/hpa-frontend-rollout.yaml"

log_info "Waiting for the frontend Rollout to become Healthy..."
for i in $(seq 1 30); do
  PHASE=$(kubectl get rollout frontend -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$PHASE" == "Healthy" ]] && break
  sleep 10
done
[[ "$PHASE" == "Healthy" ]] \
  && log_ok "frontend Rollout is Healthy" \
  || log_warn "frontend Rollout phase is '${PHASE:-<none>}' — check: kubectl get rollout frontend -n online-boutique"

# --- Step 3: productcatalogservice -> blue-green Rollout ---
log_info "Converting productcatalogservice from Deployment to Rollout (blue-green)..."
kubectl delete deployment productcatalogservice -n online-boutique --ignore-not-found=true
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/rollout-productcatalogservice-bluegreen.yaml"

log_info "Waiting for the productcatalogservice Rollout to become Healthy..."
for i in $(seq 1 30); do
  PHASE=$(kubectl get rollout productcatalogservice -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$PHASE" == "Healthy" ]] && break
  sleep 10
done
[[ "$PHASE" == "Healthy" ]] \
  && log_ok "productcatalogservice Rollout is Healthy" \
  || log_warn "productcatalogservice Rollout phase is '${PHASE:-<none>}' — check: kubectl get rollout productcatalogservice -n online-boutique"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/12-progressive-delivery/scripts/verify.sh"
echo ""
echo "  Watch a live rollout (needs the kubectl argo rollouts plugin — optional,"
echo "  see README):  kubectl argo rollouts get rollout frontend -n online-boutique --watch"
echo "============================================================"
echo ""
