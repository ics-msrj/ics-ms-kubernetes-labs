#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_sim_config
require_cluster

kubectl apply -f "${MANIFEST_DIR}/namespace.yaml"
kubectl apply -f "${MANIFEST_DIR}/target-app.yaml"
kubectl apply -f "${MANIFEST_DIR}/target-vpa.yaml"
kubectl apply -f "${MANIFEST_DIR}/k6-runner.yaml"
kubectl -n "${NAMESPACE}" set resources deployment/autoscale-target --containers=server \
  --requests="cpu=${ACK_SIM_TARGET_CPU_REQUEST},memory=${ACK_SIM_TARGET_MEMORY_REQUEST}" \
  --limits="cpu=${ACK_SIM_TARGET_CPU_LIMIT},memory=${ACK_SIM_TARGET_MEMORY_LIMIT}"
kubectl -n "${NAMESPACE}" set env deployment/autoscale-target "CPU_WORK_MS=${ACK_SIM_CPU_WORK_MS}"
kubectl -n "${NAMESPACE}" rollout restart deployment/autoscale-target
kubectl -n "${NAMESPACE}" rollout status deployment/autoscale-target --timeout=180s
log_ok "VPA observation target is ready in ${NAMESPACE}; HPA is intentionally disabled."
