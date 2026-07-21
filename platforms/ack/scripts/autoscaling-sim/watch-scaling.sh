#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_sim_config
require_cluster

while true; do
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  kubectl get hpa autoscale-target -n "${NAMESPACE}" || true
  kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=autoscale-target -o wide
  kubectl get nodes -l "${ACK_WORKLOAD_LABEL_KEY}=${ACK_WORKLOAD_LABEL_VALUE}"
  kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp | tail -n 10
  sleep 15
done
