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

# --enable-app-routing-istio alone only sets the Istio Gateway API
# implementation's mode — it does not install the Gateway API CRDs, and it
# does not flip the web app routing add-on itself to enabled. Both are
# separate, required steps or the approuting-istio GatewayClass never
# appears: https://learn.microsoft.com/en-us/azure/aks/managed-gateway-api
az aks update --resource-group "${AKS_RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}" --enable-vpa --enable-keda --enable-app-routing-istio --enable-gateway-api
az aks approuting enable --resource-group "${AKS_RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}"
log_ok "Managed add-ons requested. Run connect.sh and preflight.sh after AKS reports Succeeded."
