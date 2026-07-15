#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — promote-canary.sh (Module 14 equivalent)
#
# Applies modules/14-multi-cluster-mgmt/manifests/canary-app.yaml (reused
# unmodified — it has zero infra-specific content) to both AKS clusters,
# then proves they converged on identical declared state. Same idea as
# the native track's promote-canary.sh, but there's no SSH tunnel to
# manage here — `az aks get-credentials --file` gives each cluster its
# own independent kubeconfig directly.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/14-multi-cluster-mgmt"
SECOND_AKS_RESOURCE_GROUP="${SECOND_AKS_RESOURCE_GROUP:-}"
SECOND_AKS_CLUSTER_NAME="${SECOND_AKS_CLUSTER_NAME:-}"
SECOND_KUBECONFIG="${PLATFORM_DIR}/kubeconfig-cluster2.yaml"

require_command az
require_command kubectl
require_cluster
[[ -n "$SECOND_AKS_RESOURCE_GROUP" && -n "$SECOND_AKS_CLUSTER_NAME" ]] \
  || die "SECOND_AKS_RESOURCE_GROUP and SECOND_AKS_CLUSTER_NAME must be set in aks.env."

if [[ ! -f "$SECOND_KUBECONFIG" ]]; then
  log_info "No local kubeconfig for the second cluster yet — fetching it..."
  az aks get-credentials --resource-group "$SECOND_AKS_RESOURCE_GROUP" --name "$SECOND_AKS_CLUSTER_NAME" \
    --file "$SECOND_KUBECONFIG" --overwrite-existing
fi
KUBECONFIG="$SECOND_KUBECONFIG" kubectl cluster-info >/dev/null 2>&1 \
  || die "Second cluster unreachable. Check ${SECOND_KUBECONFIG} and az account show."

echo ""
echo "================================================================"
echo "  AKS Platform Track — Multi-Cluster Promotion Demo"
echo "================================================================"
echo ""

log_info "Applying canary-app.yaml to the PRIMARY cluster..."
sed 's/__CLUSTER_LABEL__/primary/' "${NATIVE_MODULE_DIR}/manifests/canary-app.yaml" | kubectl apply -f -
kubectl rollout status deployment/canary-demo -n default --timeout=90s

log_info "Applying the SAME canary-app.yaml to the SECOND cluster..."
sed 's/__CLUSTER_LABEL__/second/' "${NATIVE_MODULE_DIR}/manifests/canary-app.yaml" | KUBECONFIG="$SECOND_KUBECONFIG" kubectl apply -f -
KUBECONFIG="$SECOND_KUBECONFIG" kubectl rollout status deployment/canary-demo -n default --timeout=90s

echo ""
echo "--- Proving both clusters converged on the identical declared spec ---"
PRIMARY_IMAGE=$(kubectl get deployment canary-demo -n default -o jsonpath='{.spec.template.spec.containers[0].image}')
SECOND_IMAGE=$(KUBECONFIG="$SECOND_KUBECONFIG" kubectl get deployment canary-demo -n default -o jsonpath='{.spec.template.spec.containers[0].image}')
FAIL=0
if [[ "$PRIMARY_IMAGE" == "$SECOND_IMAGE" ]]; then
  log_ok "Same image on both clusters: ${PRIMARY_IMAGE}"
else
  log_error "Image drift: primary=${PRIMARY_IMAGE} second=${SECOND_IMAGE}"
  FAIL=1
fi

echo ""
echo "--- Proving each cluster still knows which one it is ---"
PRIMARY_CONTENT=$(kubectl get configmap canary-demo-content -n default -o jsonpath='{.data.index\.html}')
SECOND_CONTENT=$(KUBECONFIG="$SECOND_KUBECONFIG" kubectl get configmap canary-demo-content -n default -o jsonpath='{.data.index\.html}')
if [[ "$PRIMARY_CONTENT" == *"Running on: primary"* ]]; then
  log_ok "Primary content identifies the primary cluster"
else
  log_error "Primary content is missing its expected cluster label"
  FAIL=1
fi
if [[ "$SECOND_CONTENT" == *"Running on: second"* ]]; then
  log_ok "Second content identifies the second cluster"
else
  log_error "Second content is missing its expected cluster label"
  FAIL=1
fi

if (( FAIL > 0 )); then
  echo ""
  echo "  Promotion verification failed. Both clusters did not converge as expected." >&2
  exit 1
fi

echo ""
echo "================================================================"
echo "  Done. Same manifest, two independent AKS clusters, both converged."
echo "  Clean up: kubectl delete -f ${NATIVE_MODULE_DIR}/manifests/canary-app.yaml (each cluster)"
echo "================================================================"
echo ""
