#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command az
require_command jq
require_config
require_cluster

NODEPOOL=$(az aks nodepool show --resource-group "${AKS_RESOURCE_GROUP}" --cluster-name "${AKS_CLUSTER_NAME}" --name "${WORKLOAD_NODEPOOL}" -o json)
AUTOSCALING=$(jq -r '.enableAutoScaling' <<<"${NODEPOOL}")
MIN_COUNT=$(jq -r '.minCount' <<<"${NODEPOOL}")
MAX_COUNT=$(jq -r '.maxCount' <<<"${NODEPOOL}")
[[ "${AUTOSCALING}" == "true" ]] || die "AKS node pool ${WORKLOAD_NODEPOOL} does not have cluster autoscaler enabled."
[[ "${MIN_COUNT}" == "${MIN_NODES}" && "${MAX_COUNT}" == "${MAX_NODES}" ]] || die "Node pool bounds are ${MIN_COUNT}-${MAX_COUNT}; expected ${MIN_NODES}-${MAX_NODES}."

kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null || die "Metrics Server API is unavailable. HPA cannot be validated."
kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers || die "VPA CRD is not installed."
kubectl get nodes -l "${WORKLOAD_NODE_LABEL_KEY}=${WORKLOAD_NODE_LABEL_VALUE}" --no-headers | grep -q . || die "No node has ${WORKLOAD_NODE_LABEL_KEY}=${WORKLOAD_NODE_LABEL_VALUE}."
kubectl get service -n "${PROMETHEUS_NAMESPACE}" "${PROMETHEUS_SERVICE}" >/dev/null || die "Prometheus Service ${PROMETHEUS_SERVICE} not found in ${PROMETHEUS_NAMESPACE}."

if [[ "${REQUIRE_OPENCOST}" == "true" ]]; then
  kubectl get service -n "${OPENCOST_NAMESPACE}" "${OPENCOST_SERVICE}" >/dev/null || die "OpenCost is required but its Service was not found."
fi

log_ok "Preflight passed: AKS node pool ${WORKLOAD_NODEPOOL} autoscaling ${MIN_COUNT}-${MAX_COUNT}; workload label ${WORKLOAD_NODE_LABEL_KEY}=${WORKLOAD_NODE_LABEL_VALUE}."
