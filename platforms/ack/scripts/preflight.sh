#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command aliyun
require_command jq
require_command kubectl
require_command helm
require_config
require_storage_config
require_cluster

cluster="$(ack_cluster_json)" || die "Unable to query ACK cluster ${ACK_CLUSTER_ID} through profile ${ACK_PROFILE}."
state="$(jq -r '.state // .State // empty' <<<"${cluster}")"
region="$(jq -r '.regionId // .region_id // empty' <<<"${cluster}")"
name="$(jq -r '.name // empty' <<<"${cluster}")"

[[ "${state}" == "running" ]] || die "ACK cluster state is '${state:-unknown}', expected 'running'."
[[ "${region}" == "${ACK_REGION}" ]] || die "ACK cluster region is '${region:-unknown}', expected '${ACK_REGION}'."
[[ "${name}" == "${ACK_CLUSTER_NAME}" ]] || die "ACK cluster name is '${name:-unknown}', expected '${ACK_CLUSTER_NAME}'."

kubectl get storageclass "${ACK_STORAGE_CLASS}" >/dev/null \
  || die "StorageClass ${ACK_STORAGE_CLASS} was not found. Run: kubectl get storageclass"
kubectl get csidriver diskplugin.csi.alibabacloud.com >/dev/null \
  || die "ACK CSI disk driver was not found. Check ACK Add-ons before continuing."
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null \
  || die "Metrics API is unavailable. Wait for ACK metrics-server before continuing."
kubectl get nodes -l "${ACK_WORKLOAD_LABEL_KEY}=${ACK_WORKLOAD_LABEL_VALUE}" --no-headers | grep -q . \
  || die "No registered node has ${ACK_WORKLOAD_LABEL_KEY}=${ACK_WORKLOAD_LABEL_VALUE}. Label the ACK workload node pool, not individual nodes."

if kubectl get daemonset terway-eniip -n kube-system >/dev/null 2>&1; then
  log_ok "ACK ${ACK_CLUSTER_NAME}: Terway, CSI disk storage, metrics, and workload-pool labels are ready."
else
  log_warn "Could not find daemonset/terway-eniip by name. Confirm Terway is the cluster CNI in the ACK console before Module 04."
fi

if kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers; then
  log_ok "VPA API is available."
else
  log_warn "VPA API is absent. Install ack-vertical-pod-autoscaler through ACK Console -> Operations -> Add-ons before Module 07."
fi
