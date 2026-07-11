#!/bin/bash
# =============================================================================
# Module 02 — Core Workloads — setup.sh
#
# Deploys Online Boutique plus the supplementary manifests that make this
# module cover every core K8s workload type (the upstream app alone only
# uses Deployments):
#   - StatefulSet : redis-cart, replacing the upstream Deployment
#   - Job         : one-shot frontend smoke test (applied in verify.sh)
#   - CronJob     : cart-housekeeping, scheduled redis stats
#   - DaemonSet   : node-exporter, one pod per node
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 02 — Core Workloads — Setup"
echo "============================================================"
echo ""

log_info "Creating namespace..."
kubectl apply -f "${MODULE_DIR}/manifests/namespace.yaml"
log_ok "Namespace online-boutique ready"

log_info "Installing local-path-provisioner (placeholder StorageClass until Module 05)..."
kubectl apply -f "${MODULE_DIR}/manifests/local-path-provisioner.yaml"
kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=120s
log_ok "local-path-provisioner ready"

log_info "Deploying Online Boutique (upstream, unmodified) into online-boutique..."
kubectl apply -n online-boutique -f "${REPO_ROOT}/workloads/online-boutique/upstream/kubernetes-manifests.yaml"
log_ok "Online Boutique manifests applied"

log_info "Replacing the upstream redis-cart Deployment with a StatefulSet..."
kubectl delete deployment redis-cart -n online-boutique --ignore-not-found=true
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/redis-cart-statefulset.yaml"
log_ok "redis-cart is now a StatefulSet with persistent storage"

log_info "Deploying cart-housekeeping CronJob..."
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/cart-housekeeping-cronjob.yaml"
log_ok "CronJob scheduled"

log_info "Deploying node-exporter DaemonSet..."
kubectl apply -f "${MODULE_DIR}/manifests/node-exporter-daemonset.yaml"
log_ok "DaemonSet deployed"

log_info "Waiting for Online Boutique deployments to roll out (this can take a few minutes on first pull)..."
for dep in frontend cartservice checkoutservice currencyservice emailservice paymentservice \
           productcatalogservice recommendationservice shippingservice adservice loadgenerator; do
  kubectl rollout status "deployment/${dep}" -n online-boutique --timeout=180s \
    || log_warn "${dep} not ready yet — check with: kubectl get pods -n online-boutique"
done

log_info "Waiting for redis-cart StatefulSet..."
kubectl rollout status statefulset/redis-cart -n online-boutique --timeout=120s \
  || log_warn "redis-cart not ready yet — check the local-path PVC: kubectl get pvc -n online-boutique"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/02-core-workloads/scripts/verify.sh"
echo "============================================================"
echo ""
