#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command gcloud
require_command jq
require_command kubectl
require_command helm
require_config
require_cluster

CLUSTER=$(gcloud container clusters describe "${GKE_CLUSTER_NAME}" --zone "${GKE_ZONE}" --project "${GKE_PROJECT_ID}" --format=json)
STATUS=$(jq -r '.status' <<<"${CLUSTER}")
VERSION=$(jq -r '.currentMasterVersion' <<<"${CLUSTER}")
[[ "${STATUS}" == "RUNNING" ]] || die "GKE cluster status is ${STATUS}, not RUNNING."

NODEPOOL=$(gcloud container node-pools describe "${GKE_WORKLOAD_NODEPOOL}" --cluster "${GKE_CLUSTER_NAME}" --zone "${GKE_ZONE}" --project "${GKE_PROJECT_ID}" --format=json)
AUTOSCALING=$(jq -r '.autoscaling.enabled' <<<"${NODEPOOL}")
NODE_LABEL=$(jq -r --arg key "${GKE_WORKLOAD_LABEL_KEY}" '.config.labels[$key] // empty' <<<"${NODEPOOL}")
[[ "${AUTOSCALING}" == "true" ]] || die "Workload node pool ${GKE_WORKLOAD_NODEPOOL} must have autoscaling enabled."
[[ "${NODE_LABEL}" == "${GKE_WORKLOAD_LABEL_VALUE}" ]] || die "Node pool ${GKE_WORKLOAD_NODEPOOL} must be labelled ${GKE_WORKLOAD_LABEL_KEY}=${GKE_WORKLOAD_LABEL_VALUE}."

kubectl get storageclass "${GKE_STORAGE_CLASS}" >/dev/null || die "GKE storage class ${GKE_STORAGE_CLASS} was not found."
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null || die "Metrics Server API is unavailable."
kubectl get nodes -l "${GKE_WORKLOAD_LABEL_KEY}=${GKE_WORKLOAD_LABEL_VALUE}" --no-headers | grep -q . || die "No registered node has the workload label."

if kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers; then
  log_ok "GKE ${VERSION}: VPA API, metrics, Persistent Disk CSI, and workload pool are ready."
else
  log_warn "VPA API is absent. Run enable-managed-addons.sh before VPA-first autoscaling tests."
fi
