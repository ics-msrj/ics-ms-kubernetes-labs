#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command az
require_command kubectl
require_config

az account show -o none
log_info "Merging credentials for ${AKS_CLUSTER_NAME} into the local kubeconfig..."
az aks get-credentials --resource-group "${AKS_RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}" --overwrite-existing
require_cluster
log_ok "Connected to AKS cluster ${AKS_CLUSTER_NAME}."
