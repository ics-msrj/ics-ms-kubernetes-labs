#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config
require_storage_config
require_cluster

fail=0
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    log_ok "${description}"
  else
    log_error "${description}"
    fail=1
  fi
}

check "ACK disk StorageClass exists" kubectl get storageclass "${ACK_STORAGE_CLASS}"
check "ACK CSI disk driver exists" kubectl get csidriver diskplugin.csi.alibabacloud.com
check "Workload pool has registered nodes" bash -c "kubectl get nodes -l '${ACK_WORKLOAD_LABEL_KEY}=${ACK_WORKLOAD_LABEL_VALUE}' --no-headers | grep -q ."
check "Online Boutique namespace exists" kubectl get namespace online-boutique
check "redis-cart PVC uses the configured StorageClass" bash -c "[[ \$(kubectl get pvc redis-data-redis-cart-0 -n online-boutique -o jsonpath='{.spec.storageClassName}') == '${ACK_STORAGE_CLASS}' ]]"
check "redis-cart snapshot is ready" bash -c "[[ \$(kubectl get volumesnapshot redis-cart-snapshot -n online-boutique -o jsonpath='{.status.readyToUse}') == true ]]"

if kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers; then
  check "VPA recommendation object exists" kubectl get vpa productcatalogservice -n online-boutique
else
  log_warn "VPA API absent; scaling adapter has not been enabled."
fi

if [[ "${fail}" -ne 0 ]]; then
  die "ACK platform verification failed."
fi
log_ok "ACK platform foundation verification passed."
