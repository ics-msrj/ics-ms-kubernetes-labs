#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command az
require_command jq
require_command kubectl
require_command helm
require_config
require_cluster

CLUSTER=$(az aks show --resource-group "${AKS_RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}" -o json)
STATE=$(jq -r '.provisioningState' <<<"${CLUSTER}")
VERSION=$(jq -r '.kubernetesVersion' <<<"${CLUSTER}")
[[ "${STATE}" == "Succeeded" ]] || die "AKS provisioning state is ${STATE}, not Succeeded."

NODEPOOL=$(az aks nodepool show --resource-group "${AKS_RESOURCE_GROUP}" --cluster-name "${AKS_CLUSTER_NAME}" --name "${AKS_WORKLOAD_NODEPOOL}" -o json)
AUTOSCALING=$(jq -r '.enableAutoScaling' <<<"${NODEPOOL}")
NODE_LABEL=$(jq -r --arg key "${AKS_WORKLOAD_LABEL_KEY}" '.nodeLabels[$key] // empty' <<<"${NODEPOOL}")
[[ "${AUTOSCALING}" == "true" ]] || die "Workload node pool ${AKS_WORKLOAD_NODEPOOL} must have Cluster Autoscaler enabled."
[[ "${NODE_LABEL}" == "${AKS_WORKLOAD_LABEL_VALUE}" ]] || die "Node pool ${AKS_WORKLOAD_NODEPOOL} must be labelled ${AKS_WORKLOAD_LABEL_KEY}=${AKS_WORKLOAD_LABEL_VALUE}."

kubectl get storageclass "${AKS_STORAGE_CLASS}" >/dev/null || die "AKS storage class ${AKS_STORAGE_CLASS} was not found."
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null || die "Metrics Server API is unavailable."
kubectl get nodes -l "${AKS_WORKLOAD_LABEL_KEY}=${AKS_WORKLOAD_LABEL_VALUE}" --no-headers | grep -q . || die "No registered node has the workload label."

if kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers; then
  log_ok "AKS ${VERSION}: VPA API, metrics, Azure Disk CSI, and workload pool are ready."
else
  log_warn "VPA API is absent. Run enable-managed-addons.sh before VPA-first autoscaling tests."
fi
