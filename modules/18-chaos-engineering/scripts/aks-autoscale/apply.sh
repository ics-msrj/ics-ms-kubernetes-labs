#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_cluster

kubectl apply -f "${MANIFEST_DIR}/namespace.yaml"
kubectl apply -f "${MANIFEST_DIR}/target-app.yaml"
kubectl apply -f "${MANIFEST_DIR}/target-vpa.yaml"
kubectl apply -f "${MANIFEST_DIR}/k6-runner.yaml"
kubectl -n "${NAMESPACE}" wait --for=condition=Available deployment/autoscale-target --timeout=180s
log_ok "VPA observation target is ready in namespace ${NAMESPACE}; HPA is intentionally not enabled yet."
