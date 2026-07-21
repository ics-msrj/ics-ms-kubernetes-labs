#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_sim_config
require_cluster

[[ "${ACK_SIM_VPA_REVIEWED}" == "true" ]] \
  || die "Review the VPA recommendation, set request values in ${SIM_CONFIG_FILE}, then set ACK_SIM_VPA_REVIEWED=true."
mode="$(kubectl -n "${NAMESPACE}" get vpa autoscale-target -o jsonpath='{.spec.updatePolicy.updateMode}')"
[[ "${mode}" == "Off" ]] || die "Refusing to enable HPA: VPA must be Off, found ${mode}."
kubectl apply -f "${MANIFEST_DIR}/target-hpa.yaml"
kubectl -n "${NAMESPACE}" patch hpa autoscale-target --type merge -p "{\"spec\":{\"minReplicas\":${ACK_SIM_MIN_REPLICAS},\"maxReplicas\":${ACK_SIM_MAX_REPLICAS},\"metrics\":[{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":${ACK_SIM_HPA_CPU_TARGET}}}}]}}"
log_ok "HPA enabled with ${ACK_SIM_MIN_REPLICAS}-${ACK_SIM_MAX_REPLICAS} replicas at ${ACK_SIM_HPA_CPU_TARGET}% CPU while VPA remains Off."
