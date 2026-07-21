#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config

if [[ -z "${KUBECONFIG:-}" ]]; then
  die "KUBECONFIG is not set. Download a temporary kubeconfig from the ACK console, export KUBECONFIG=/path/to/file, then re-run."
fi
[[ -r "${KUBECONFIG}" ]] || die "KUBECONFIG is not readable: ${KUBECONFIG}"
require_cluster

log_ok "Connected to ACK cluster ${ACK_CLUSTER_NAME} using context $(kubectl config current-context)."
log_info "This script does not persist or modify kubeconfig credentials."
