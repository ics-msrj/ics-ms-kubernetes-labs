#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_sim_config
require_cluster
read -rp "Delete only the ${NAMESPACE} simulation namespace and its load jobs? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }
kubectl delete namespace "${NAMESPACE}" --ignore-not-found
log_ok "Simulation namespace deleted. ACK node-pool settings and Online Boutique were not changed."
