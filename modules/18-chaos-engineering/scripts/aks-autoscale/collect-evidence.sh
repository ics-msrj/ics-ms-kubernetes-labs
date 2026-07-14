#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

SCENARIO="${1:?Usage: collect-evidence.sh <scenario> [artifact-dir]}"
RUN_ARTIFACT_DIR="${2:-}"
if [[ -z "${RUN_ARTIFACT_DIR}" ]]; then new_artifact_dir "${SCENARIO}"; fi
mkdir -p "${RUN_ARTIFACT_DIR}"

kubectl get nodes -o wide >"${RUN_ARTIFACT_DIR}/nodes.txt"
kubectl get pods -n "${NAMESPACE}" -o wide >"${RUN_ARTIFACT_DIR}/pods.txt"
kubectl get hpa,vpa -n "${NAMESPACE}" -o yaml >"${RUN_ARTIFACT_DIR}/autoscalers.yaml"
kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp >"${RUN_ARTIFACT_DIR}/events.txt"
kubectl top nodes >"${RUN_ARTIFACT_DIR}/node-usage.txt" 2>&1 || true
kubectl top pods -n "${NAMESPACE}" >"${RUN_ARTIFACT_DIR}/pod-usage.txt" 2>&1 || true

if kubectl get service -n "${OPENCOST_NAMESPACE}" "${OPENCOST_SERVICE}" >/dev/null 2>&1; then
  kubectl -n "${OPENCOST_NAMESPACE}" run "opencost-evidence-$$" --image=curlimages/curl:8.10.1 --restart=Never --rm -q -i --timeout=45s \
    --overrides='{"spec":{"automountServiceAccountToken":false,"containers":[{"name":"curl","image":"curlimages/curl:8.10.1","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":10000,"capabilities":{"drop":["ALL"]}}}]}}' \
    -- curl -fsS "http://${OPENCOST_SERVICE}.${OPENCOST_NAMESPACE}.svc:9003/allocation/compute?window=1h" >"${RUN_ARTIFACT_DIR}/opencost-allocation.json" 2>/dev/null || true
fi

log_ok "Evidence saved to ${RUN_ARTIFACT_DIR}."
