#!/usr/bin/env bash
# =============================================================================
# GKE Platform Track — enable-scaling.sh
#
# The GKE equivalent of Module 07. metrics-server and VPA (steps 1-2 of
# Module 07's own setup.sh) are already covered before this script even
# runs: GKE ships metrics-server pre-installed (confirmed live:
# `kubectl top nodes` already works), and VPA is the managed add-on
# enable-managed-addons.sh already turned on (`--enable-vertical-pod-
# autoscaling`) — its controllers run as a hidden GKE-managed component,
# not visible as ordinary Deployments the way AKS's --enable-vpa add-on
# is, but the verticalpodautoscalers API is registered and that's what
# the VPA object below actually needs to exist.
#
# Unlike AKS (which has a first-party managed KEDA add-on), GKE has none
# — step 3 (KEDA) is NOT already covered and still needs the native
# module's own Helm install, same as the kubeadm track itself.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/07-scalability-ha"
KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-2.20.1}"

require_command kubectl
require_command helm
require_cluster
kubectl get namespace online-boutique >/dev/null || die "Namespace online-boutique not found. Run deploy-core-workloads first."
kubectl top nodes >/dev/null 2>&1 || die "metrics-server is not serving metrics yet (GKE ships it pre-installed — give it a minute after cluster creation)."
kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers \
  || die "VPA API not found. Run enable-managed-addons.sh and wait for it to finish first."

echo ""
echo "================================================================"
echo "  GKE Platform Track — Scaling (Module 07 equivalent)"
echo "================================================================"
echo ""

if kubectl get deployment keda-operator -n keda &>/dev/null; then
  log_info "KEDA already installed — skipping"
else
  log_info "Installing KEDA v${KEDA_CHART_VERSION} (no GKE-managed equivalent, unlike AKS)..."
  helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
  helm repo update kedacore >/dev/null
  helm install keda kedacore/keda \
    --version "${KEDA_CHART_VERSION}" \
    --namespace keda --create-namespace
fi
for dep in keda-operator keda-operator-metrics-apiserver keda-admission-webhooks; do
  kubectl rollout status "deployment/${dep}" -n keda --timeout=120s
done
log_ok "KEDA ready"

log_info "Scaling cartservice to 2 replicas (so its PDB has something to protect)..."
kubectl scale deployment cartservice -n online-boutique --replicas=2
kubectl rollout status deployment/cartservice -n online-boutique --timeout=120s

log_info "Applying HPA, VPA, KEDA ScaledObject, and PodDisruptionBudgets (reused unmodified from Module 07)..."
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/hpa-frontend.yaml"
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/vpa-productcatalogservice.yaml"
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/keda-scaledobject-loadgenerator.yaml"
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/pdb-frontend.yaml"
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/pdb-cartservice.yaml"
log_ok "Autoscaling and disruption-budget objects applied"

echo ""
echo "================================================================"
echo "  Scaling ready."
echo "================================================================"
echo ""
