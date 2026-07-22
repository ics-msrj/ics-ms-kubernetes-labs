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
REDIS_STORAGE_CLASS="${REDIS_STORAGE_CLASS:-longhorn}"
REDIS_STORAGE_SIZE="${REDIS_STORAGE_SIZE:-1Gi}"
# Empty by default (native kubeadm has no system/workload pool split to
# route around) — set both on AKS/GKE to keep this chart's Pods off the
# system pool. Found to matter live: without it, frontend/emailservice/
# recommendationservice landed on GKE's system pool (96% CPU requests)
# and CrashLoopBacked-off on gRPC probe timeouts, invisible in their own
# logs — see the matching note in charts/online-boutique/values.yaml.
WORKLOAD_NODE_SELECTOR_KEY="${WORKLOAD_NODE_SELECTOR_KEY:-}"
WORKLOAD_NODE_SELECTOR_VALUE="${WORKLOAD_NODE_SELECTOR_VALUE:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get storageclass "${REDIS_STORAGE_CLASS}" &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} StorageClass ${REDIS_STORAGE_CLASS} not found. Complete Module 05 first, or set REDIS_STORAGE_CLASS to an existing one." >&2
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

log_info "Installing the chart into online-boutique-packaged (storageClassName: ${REDIS_STORAGE_CLASS})..."
REDIS_PASSWORD="$(openssl rand -hex 16)"
HELM_NODE_SELECTOR_ARGS=()
if [[ -n "${WORKLOAD_NODE_SELECTOR_KEY}" ]]; then
  HELM_NODE_SELECTOR_ARGS=(--set "nodeSelector.${WORKLOAD_NODE_SELECTOR_KEY}=${WORKLOAD_NODE_SELECTOR_VALUE}")
fi
helm upgrade --install online-boutique "${REPO_ROOT}/charts/online-boutique" \
  --namespace online-boutique-packaged --create-namespace \
  --set redisCart.password="${REDIS_PASSWORD}" \
  --set redisCart.storageClassName="${REDIS_STORAGE_CLASS}" \
  --set redisCart.storageSize="${REDIS_STORAGE_SIZE}" \
  "${HELM_NODE_SELECTOR_ARGS[@]}" \
  --wait --timeout 5m
unset REDIS_PASSWORD
log_ok "Chart deployed — 11 Deployments + 1 StatefulSet from one set of templates"

# --- Part B: Kustomize — render all 3 overlays for inspection ---
# Kustomize's helmCharts inflation has no --set equivalent — values only
# come from kustomize/base/kustomization.yaml's own (committed, shared
# across dev/staging/prod) config. To override redisCart.storageClassName
# without editing that shared file in place (which would break native
# parity for anyone else running this module against Longhorn), copy the
# whole kustomize/ tree to a scratch dir and inject a valuesInline block
# there instead — the committed files are never touched.
KUSTOMIZE_SRC="${REPO_ROOT}/kustomize"
if [[ "${REDIS_STORAGE_CLASS}" != "longhorn" || "${REDIS_STORAGE_SIZE}" != "1Gi" || -n "${WORKLOAD_NODE_SELECTOR_KEY}" ]]; then
  KUSTOMIZE_ROOT="$(mktemp -d)"
  trap 'rm -rf "$KUSTOMIZE_ROOT"' EXIT
  cp -r "${KUSTOMIZE_SRC}/." "${KUSTOMIZE_ROOT}/"
  python3 - "${KUSTOMIZE_ROOT}/base/kustomization.yaml" "${REDIS_STORAGE_CLASS}" "${REDIS_STORAGE_SIZE}" "${WORKLOAD_NODE_SELECTOR_KEY}" "${WORKLOAD_NODE_SELECTOR_VALUE}" "${REPO_ROOT}/charts" <<'PYEOF'
import sys, yaml
path, storage_class, storage_size, selector_key, selector_value, chart_home = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
with open(path) as f:
    doc = yaml.safe_load(f)
values = {"redisCart": {"storageClassName": storage_class, "storageSize": storage_size}}
if selector_key:
    values["nodeSelector"] = {selector_key: selector_value}
doc["helmCharts"][0]["valuesInline"] = values
# helmGlobals.chartHome (../../charts) is relative to this file's location
# in the real repo — copied into a scratch dir at a different depth, that
# relative path no longer resolves. Point it at the real charts/ directly
# instead of trying to preserve the original directory depth in the copy.
doc["helmGlobals"]["chartHome"] = chart_home
with open(path, "w") as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PYEOF
else
  KUSTOMIZE_ROOT="${KUSTOMIZE_SRC}"
fi

log_info "Rendering all 3 Kustomize overlays (dev/staging/prod) to ${GENERATED_DIR}/..."
mkdir -p "$GENERATED_DIR"
for env in dev staging prod; do
  kustomize build "${KUSTOMIZE_ROOT}/overlays/${env}" \
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
