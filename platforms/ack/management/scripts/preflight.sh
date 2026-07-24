#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

for command in kubectl helm curl git jq aliyun terraform; do
  require_command "${command}"
done
require_config
require_cluster
require_rancher_config

echo ""
echo "================================================================"
echo "  ACK Rancher Management Cluster - Preflight"
echo "================================================================"
echo ""

log_ok "kubectl reaches ${ACK_MANAGEMENT_CLUSTER_NAME}"
log_info "Current context: $(kubectl config current-context)"
log_info "Cluster nodes: $(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"

NODE_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if (( NODE_COUNT < 3 )); then
  die "Management cluster has ${NODE_COUNT} node(s); Rancher HA requires three management nodes."
fi

if kubectl get namespace online-boutique >/dev/null 2>&1; then
  die "online-boutique exists on this cluster. Refusing to use a workload cluster as the Rancher management cluster."
fi

if kubectl get deployment rancher -n cattle-system >/dev/null 2>&1; then
  log_warn "Rancher already exists in cattle-system; enable-rancher will reconcile it."
fi

log_ok "Dedicated-management-cluster guard passed"
echo ""
echo "Next: bash platforms/ack/management/scripts/platform-track.sh bootstrap"
