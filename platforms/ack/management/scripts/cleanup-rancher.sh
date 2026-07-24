#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command helm
require_config
require_cluster

echo "This removes Rancher only from ${ACK_MANAGEMENT_CLUSTER_NAME}. Imported clusters"
echo "keep running, but their cattle-cluster-agent deployments lose their management"
echo "server connection until Rancher is restored or agents are removed downstream."
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

if kubectl get namespace cattle-system >/dev/null 2>&1; then
  helm uninstall rancher -n cattle-system --wait --timeout 10m || true
  kubectl delete namespace cattle-system --ignore-not-found=true --wait=true
  log_ok "Rancher management server removed."
else
  log_info "cattle-system does not exist; nothing to remove."
fi
