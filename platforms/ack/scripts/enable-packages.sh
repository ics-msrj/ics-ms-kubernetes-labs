#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command helm
require_command kustomize
require_storage_config
require_cluster
REDIS_STORAGE_CLASS="${ACK_STORAGE_CLASS}" \
WORKLOAD_NODE_SELECTOR_KEY="${ACK_WORKLOAD_LABEL_KEY}" \
WORKLOAD_NODE_SELECTOR_VALUE="${ACK_WORKLOAD_LABEL_VALUE}" \
  bash "${REPO_ROOT}/modules/10-package-management/scripts/setup.sh"
