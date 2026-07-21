#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config
require_storage_config
require_cluster

kubectl get statefulset redis-cart -n online-boutique >/dev/null 2>&1 \
  || die "redis-cart StatefulSet not found. Run deploy-core-workloads.sh first."
current_sc="$(kubectl get pvc redis-data-redis-cart-0 -n online-boutique -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
[[ "${current_sc}" == "${ACK_STORAGE_CLASS}" ]] \
  || die "redis-cart PVC uses '${current_sc:-none}', expected '${ACK_STORAGE_CLASS}'."
kubectl get crd volumesnapshots.snapshot.storage.k8s.io >/dev/null 2>&1 \
  || die "VolumeSnapshot CRDs are absent. Enable and update ACK CSI components first."

log_info "Creating an ACK CSI VolumeSnapshotClass and snapshotting redis-cart..."
kubectl apply -f "${PLATFORM_DIR}/manifests/volumesnapshotclass.yaml"
kubectl delete volumesnapshot redis-cart-snapshot -n online-boutique --ignore-not-found=true --wait=true
kubectl apply -f "${PLATFORM_DIR}/manifests/redis-cart-snapshot.yaml"

ready=""
for _ in $(seq 1 36); do
  ready="$(kubectl get volumesnapshot redis-cart-snapshot -n online-boutique -o jsonpath='{.status.readyToUse}' 2>/dev/null || true)"
  [[ "${ready}" == "true" ]] && break
  sleep 5
done

if [[ "${ready}" == "true" ]]; then
  log_ok "Snapshot redis-cart-snapshot is ready. ECS snapshots are billable until deleted."
else
  die "Snapshot did not become ready. Inspect: kubectl describe volumesnapshot redis-cart-snapshot -n online-boutique"
fi
