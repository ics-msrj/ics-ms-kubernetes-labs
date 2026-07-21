#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

scenario="${1:?Usage: collect-evidence.sh <scenario> [artifact-dir]}"
artifact_dir="${2:-}"
require_command aliyun
if [[ -z "${artifact_dir}" ]]; then
  new_artifact_dir "${scenario}"
  artifact_dir="${RUN_ARTIFACT_DIR}"
fi
mkdir -p "${artifact_dir}"

kubectl get nodes -o wide >"${artifact_dir}/nodes.txt"
kubectl get pods -n "${NAMESPACE}" -o wide >"${artifact_dir}/pods.txt"
kubectl get hpa,vpa -n "${NAMESPACE}" -o yaml >"${artifact_dir}/autoscalers.yaml"
kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp >"${artifact_dir}/events.txt"
kubectl top nodes >"${artifact_dir}/node-usage.txt" 2>&1 || true
kubectl top pods -n "${NAMESPACE}" >"${artifact_dir}/pod-usage.txt" 2>&1 || true
ack_nodepools_json >"${artifact_dir}/ack-nodepools.json" 2>&1 || true

log_ok "Evidence saved to ${artifact_dir}."
