#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config
require_cluster

MODE=$(kubectl -n "${NAMESPACE}" get vpa autoscale-target -o jsonpath='{.spec.updatePolicy.updateMode}')
[[ "${MODE}" == "Off" ]] || die "Refusing to enable HPA: VPA must be Off, found ${MODE}."
kubectl apply -f "${MANIFEST_DIR}/target-hpa.yaml"
kubectl -n "${NAMESPACE}" patch hpa autoscale-target --type merge -p "$(cat <<EOF
{"spec":{"minReplicas":${MIN_REPLICAS},"maxReplicas":${MAX_REPLICAS},"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":${HPA_CPU_TARGET:-70}}}}]}}
EOF
)"
log_ok "HPA enabled with ${MIN_REPLICAS}-${MAX_REPLICAS} replicas and CPU target ${HPA_CPU_TARGET:-70}% while VPA remains Off."
