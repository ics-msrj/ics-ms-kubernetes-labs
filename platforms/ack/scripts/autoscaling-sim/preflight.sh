#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command aliyun
require_command jq
require_sim_config
require_cluster

nodepool="$(ack_nodepools_json | jq -ce --arg name "${ACK_WORKLOAD_NODEPOOL}" \
  '.nodepools[] | select(.nodepool_info.name == $name)')" \
  || die "ACK node pool ${ACK_WORKLOAD_NODEPOOL} was not found."
enabled="$(jq -r '.auto_scaling.enable' <<<"${nodepool}")"
min_nodes="$(jq -r '.auto_scaling.min_instances' <<<"${nodepool}")"
max_nodes="$(jq -r '.auto_scaling.max_instances' <<<"${nodepool}")"
[[ "${enabled}" == "true" ]] || die "ACK node pool ${ACK_WORKLOAD_NODEPOOL} does not have autoscaling enabled."
[[ "${min_nodes}" == "${ACK_SIM_MIN_NODES}" && "${max_nodes}" == "${ACK_SIM_MAX_NODES}" ]] \
  || die "ACK node pool bounds are ${min_nodes}-${max_nodes}; expected ${ACK_SIM_MIN_NODES}-${ACK_SIM_MAX_NODES}."

kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null \
  || die "Metrics API is unavailable. HPA cannot be validated."
kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers \
  || die "ACK VPA API is not installed. Apply the ACK Terraform foundation first."
kubectl get nodes -l "${ACK_WORKLOAD_LABEL_KEY}=${ACK_WORKLOAD_LABEL_VALUE}" --no-headers | grep -q . \
  || die "No node has ${ACK_WORKLOAD_LABEL_KEY}=${ACK_WORKLOAD_LABEL_VALUE}."

log_ok "Preflight passed: ACK node pool ${ACK_WORKLOAD_NODEPOOL} autoscaling ${min_nodes}-${max_nodes}; workload label ${ACK_WORKLOAD_LABEL_KEY}=${ACK_WORKLOAD_LABEL_VALUE}."
