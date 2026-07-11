#!/bin/bash
# =============================================================================
# Module 10 — Package Management — setup.sh
#
# 1. Installs the charts/online-boutique Helm chart into a fresh namespace
#    (online-boutique-packaged) — proves the authored chart actually works,
#    with zero risk to the online-boutique namespace every other module uses
# 2. Renders all 3 Kustomize overlays (dev/staging/prod) for inspection/diff
# 3. Applies the dev overlay live into online-boutique-dev — the one
#    environment this module actually deploys; staging/prod stay render-only
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
GENERATED_DIR="${MODULE_DIR}/generated"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get storageclass longhorn &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} StorageClass longhorn not found. Complete Module 05 first." >&2
  exit 1
fi
if ! command -v kustomize &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kustomize CLI not found. Complete Module 00 first (or: bash modules/00-prerequisites/scripts/setup.sh)." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 10 — Package Management — Setup"
echo "============================================================"
echo ""

# --- Part A: Helm chart, deployed to prove it works ---
log_info "Linting charts/online-boutique..."
helm lint "${REPO_ROOT}/charts/online-boutique"

log_info "Installing the chart into online-boutique-packaged..."
REDIS_PASSWORD="$(openssl rand -hex 16)"
helm upgrade --install online-boutique "${REPO_ROOT}/charts/online-boutique" \
  --namespace online-boutique-packaged --create-namespace \
  --set redisCart.password="${REDIS_PASSWORD}" \
  --wait --timeout 5m
unset REDIS_PASSWORD
log_ok "Chart deployed — 11 Deployments + 1 StatefulSet from one set of templates"

# --- Part B: Kustomize — render all 3 overlays for inspection ---
log_info "Rendering all 3 Kustomize overlays (dev/staging/prod) to ${GENERATED_DIR}/..."
mkdir -p "$GENERATED_DIR"
for env in dev staging prod; do
  kustomize build "${REPO_ROOT}/kustomize/overlays/${env}" \
    --enable-helm --helm-command helm --load-restrictor LoadRestrictionsNone \
    > "${GENERATED_DIR}/${env}.yaml"
  REPLICAS=$(grep -A2 "name: frontend$" "${GENERATED_DIR}/${env}.yaml" | grep -m1 replicas || true)
  log_info "  ${env}.yaml rendered ($(grep -c '^kind:' "${GENERATED_DIR}/${env}.yaml") objects)"
done
log_ok "All 3 overlays rendered — diff them: diff ${GENERATED_DIR}/dev.yaml ${GENERATED_DIR}/prod.yaml"

# --- Part C: apply the dev overlay live ---
log_info "Applying the dev overlay to online-boutique-dev (the only overlay this module deploys live)..."
kubectl create namespace online-boutique-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n online-boutique-dev -f "${GENERATED_DIR}/dev.yaml"

# Kustomize's helmCharts inflation renders with the chart's *default* values —
# there's no --set equivalent for a per-run random value the way `helm
# install` has, so the rendered Secret still has the chart's placeholder
# password. Overwrite it with a real one, same as the Helm install above.
DEV_REDIS_PASSWORD="$(openssl rand -hex 16)"
kubectl create secret generic redis-cart-credentials \
  --namespace online-boutique-dev \
  --from-literal=password="${DEV_REDIS_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DEV_REDIS_PASSWORD
kubectl rollout restart statefulset/redis-cart -n online-boutique-dev
kubectl rollout restart deployment/cartservice -n online-boutique-dev
log_ok "dev overlay applied with a real (non-placeholder) redis-cart password"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/10-package-management/scripts/verify.sh"
echo "============================================================"
echo ""
