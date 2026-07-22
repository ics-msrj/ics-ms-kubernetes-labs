#!/usr/bin/env bash
# Removes only the ACK-hosted Rancher management server.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command helm
require_config
require_cluster

echo "This removes Rancher from ACK only. Imported AKS/GKE clusters keep running,"
echo "but their cattle-cluster-agent deployments will no longer connect until a"
echo "Rancher server is restored or the agents are removed from each downstream cluster."
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

if kubectl get namespace cattle-system >/dev/null 2>&1; then
  helm uninstall rancher -n cattle-system --wait --timeout 10m || true
  kubectl delete namespace cattle-system --ignore-not-found=true --wait=true
  log_ok "ACK Rancher management server removed."
else
  log_info "cattle-system does not exist; nothing to remove."
fi
