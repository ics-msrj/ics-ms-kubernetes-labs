#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

native_module_dir="${REPO_ROOT}/modules/07-scalability-ha"

require_command kubectl
require_config
require_cluster
kubectl get namespace online-boutique >/dev/null \
  || die "Namespace online-boutique not found. Run deploy-core-workloads.sh first."
kubectl top nodes >/dev/null 2>&1 \
  || die "Metrics API is not serving node metrics yet."
kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers \
  || die "VPA API not found. Apply the ACK Terraform foundation and wait for the managed VPA add-on to reconcile."

log_info "Scaling cartservice to two replicas for its PodDisruptionBudget..."
kubectl scale deployment cartservice -n online-boutique --replicas=2
kubectl rollout status deployment/cartservice -n online-boutique --timeout=180s

log_info "Applying HPA, VPA in Off mode, and PodDisruptionBudgets..."
kubectl apply -f "${native_module_dir}/manifests/hpa-frontend.yaml"
kubectl apply -f "${native_module_dir}/manifests/vpa-productcatalogservice.yaml"
kubectl apply -f "${native_module_dir}/manifests/pdb-frontend.yaml"
kubectl apply -f "${native_module_dir}/manifests/pdb-cartservice.yaml"

log_warn "KEDA is deliberately not installed yet. Validate ACK-compatible KEDA resources and Module 06 resource-policy limits on the live cluster before adding the Module 07 ScaledObject."
log_ok "VPA-first HPA/PDB scaling objects are applied."
