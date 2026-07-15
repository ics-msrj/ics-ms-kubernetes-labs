#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — enable-scaling.sh
#
# The AKS equivalent of Module 07. Steps 1-3 of Module 07's own setup.sh
# (install metrics-server, install VPA, install KEDA) are all already
# covered on AKS before this script even runs: metrics-server ships
# pre-installed, and VPA/KEDA are the managed add-ons
# enable-managed-addons.sh already turned on. Installing the upstream
# charts on top would just be a second, conflicting VPA/KEDA in the
# cluster. What's actually left is Module 07's own step 4 — reused
# unmodified, since an HPA/VPA-object/ScaledObject/PDB manifest doesn't
# care whether the controller behind it is self-managed or AKS-managed.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/07-scalability-ha"

require_command kubectl
require_cluster
kubectl get namespace online-boutique >/dev/null || die "Namespace online-boutique not found. Run deploy-core-workloads first."
kubectl top nodes >/dev/null 2>&1 || die "metrics-server is not serving metrics yet (AKS ships it pre-installed — give it a minute after cluster creation)."
kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers \
  || die "VPA API not found. Run enable-managed-addons.sh and wait for it to finish first."
kubectl get deployment keda-operator -n kube-system >/dev/null 2>&1 \
  || log_warn "keda-operator not found in kube-system yet — the KEDA ScaledObject below may not reconcile until AKS's managed KEDA finishes rolling out."

echo ""
echo "================================================================"
echo "  AKS Platform Track — Scaling (Module 07 equivalent)"
echo "================================================================"
echo ""

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
