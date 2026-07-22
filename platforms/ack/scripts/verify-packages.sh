#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_storage_config
require_cluster
REDIS_STORAGE_SIZE="${ACK_REDIS_DISK_SIZE}" \
  bash "${REPO_ROOT}/modules/10-package-management/scripts/verify.sh"
