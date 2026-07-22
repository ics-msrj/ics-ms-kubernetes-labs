#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command helm
require_storage_config
require_cluster
LOKI_STORAGE_CLASS="${ACK_STORAGE_CLASS}" \
LOKI_PERSISTENCE_SIZE="${ACK_REDIS_DISK_SIZE}" \
  bash "${REPO_ROOT}/modules/09-logging/scripts/setup.sh"
