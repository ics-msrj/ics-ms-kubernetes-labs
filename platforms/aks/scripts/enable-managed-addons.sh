#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command az
require_config

echo "This enables AKS-managed VPA, KEDA, and application-routing Gateway API."
echo "It does not change node-pool size or deploy application workloads."
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

az aks update --resource-group "${AKS_RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}" --enable-vpa --enable-keda --enable-app-routing-istio
log_ok "Managed add-ons requested. Run connect.sh and preflight.sh after AKS reports Succeeded."
