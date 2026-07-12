#!/bin/bash
# =============================================================================
# Module 14 — promote-canary.sh
#
# A real multi-cluster promotion pattern, not just "import and look at it":
# applies the exact same manifest (modules/14-multi-cluster-mgmt/manifests/
# canary-app.yaml) to BOTH clusters and proves they converged on identical
# state.
#
# This is deliberately NOT an ArgoCD ApplicationSet. That would need the
# primary cluster's ArgoCD pods to reach the second cluster's real API
# server directly — which means exposing port 6443 publicly, breaking the
# tunnel-only access model every other module in this repo relies on
# (Module 01's whole design keeps 6443 off the public internet). Rancher's
# cattle-cluster-agent gets away with a cross-cluster connection because it
# phones home over the *already-public* Gateway (443), not a raw API
# server — a genuinely different network path, not just a stylistic
# choice. This script instead reuses the two SSH tunnels (:6443, :6444)
# your workstation already has open from Module 01 and this module's own
# setup.sh — no new network exposure anywhere.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
SECOND_KUBECONFIG="${MODULE_DIR}/kubeconfig-cluster2.yaml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC}  $*" >&2; }

if [[ ! -f "$SECOND_KUBECONFIG" ]]; then
  echo -e "${RED}[ERROR]${NC} ${SECOND_KUBECONFIG} not found. Run this module's setup.sh first." >&2
  exit 1
fi
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Primary cluster unreachable (:6443 tunnel). Complete Module 01 first." >&2
  exit 1
fi
if ! KUBECONFIG="$SECOND_KUBECONFIG" kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Second cluster unreachable (:6444 tunnel) — see this module's Step 1." >&2
  exit 1
fi

echo ""
echo "================================================================"
echo "  Module 14 — Multi-Cluster Promotion Demo"
echo "================================================================"
echo ""

log_info "Applying canary-app.yaml to the PRIMARY cluster..."
sed 's/__CLUSTER_LABEL__/primary/' "${MODULE_DIR}/manifests/canary-app.yaml" | kubectl apply -f -
kubectl rollout status deployment/canary-demo -n default --timeout=90s

log_info "Applying the SAME canary-app.yaml to the SECOND cluster..."
sed 's/__CLUSTER_LABEL__/second/' "${MODULE_DIR}/manifests/canary-app.yaml" | KUBECONFIG="$SECOND_KUBECONFIG" kubectl apply -f -
KUBECONFIG="$SECOND_KUBECONFIG" kubectl rollout status deployment/canary-demo -n default --timeout=90s

echo ""
echo -e "${BLUE}--- Proving both clusters converged on the identical declared spec ---${NC}"
PRIMARY_IMAGE=$(kubectl get deployment canary-demo -n default -o jsonpath='{.spec.template.spec.containers[0].image}')
SECOND_IMAGE=$(KUBECONFIG="$SECOND_KUBECONFIG" kubectl get deployment canary-demo -n default -o jsonpath='{.spec.template.spec.containers[0].image}')
FAIL=0
if [[ "$PRIMARY_IMAGE" == "$SECOND_IMAGE" ]]; then
  log_ok "Same image on both clusters: ${PRIMARY_IMAGE}"
else
  log_fail "Image drift: primary=${PRIMARY_IMAGE} second=${SECOND_IMAGE}"
  FAIL=1
fi

echo ""
echo -e "${BLUE}--- Proving each cluster still knows which one it is ---${NC}"
PRIMARY_CONTENT=$(kubectl get configmap canary-demo-content -n default -o jsonpath='{.data.index\.html}')
SECOND_CONTENT=$(KUBECONFIG="$SECOND_KUBECONFIG" kubectl get configmap canary-demo-content -n default -o jsonpath='{.data.index\.html}')
if [[ "$PRIMARY_CONTENT" == *"Running on: primary"* ]]; then
  log_ok "Primary content identifies the primary cluster"
else
  log_fail "Primary content is missing its expected cluster label"
  FAIL=1
fi
if [[ "$SECOND_CONTENT" == *"Running on: second"* ]]; then
  log_ok "Second content identifies the second cluster"
else
  log_fail "Second content is missing its expected cluster label"
  FAIL=1
fi

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Promotion verification failed. Both clusters did not converge as expected.${NC}"
  exit 1
fi

echo ""
echo "================================================================"
echo "  Done. Same manifest, two independent clusters, both converged."
echo "  Clean up: kubectl delete -f modules/14-multi-cluster-mgmt/manifests/canary-app.yaml (each cluster)"
echo "================================================================"
echo ""
