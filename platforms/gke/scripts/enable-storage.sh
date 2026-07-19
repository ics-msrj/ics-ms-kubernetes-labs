#!/usr/bin/env bash
# =============================================================================
# GKE Platform Track — enable-storage.sh
#
# The GKE equivalent of Module 05. Most of Module 05 doesn't apply here at
# all: no SSH node prerequisites (Persistent Disk CSI needs none), no
# Longhorn install (PD CSI's standard-rwo StorageClass is already GKE's
# default), and redis-cart is already on standard-rwo as of
# deploy-core-workloads.sh — there is no separate migration step the way
# there is on the native track. What's left, genuinely: confirm CSI
# snapshot support (present by default on GKE, unlike AKS which needed an
# explicit Terraform flag — verified live: the VolumeSnapshot CRDs were
# already there before this script ever ran), then take a real snapshot
# of redis-cart's volume.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_cluster

kubectl get statefulset redis-cart -n online-boutique >/dev/null 2>&1 \
  || die "redis-cart StatefulSet not found. Run deploy-core-workloads.sh first."
CURRENT_SC=$(kubectl get pvc redis-data-redis-cart-0 -n online-boutique -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
[[ "$CURRENT_SC" == "${GKE_STORAGE_CLASS}" ]] \
  || die "redis-cart's PVC is on StorageClass '${CURRENT_SC:-none}', expected '${GKE_STORAGE_CLASS}'. Re-run deploy-core-workloads.sh."

echo ""
echo "================================================================"
echo "  GKE Platform Track — Storage (Module 05 equivalent)"
echo "================================================================"
echo ""

log_info "Confirming CSI snapshot support (GKE ships this by default, no cluster flag needed)..."
kubectl get crd volumesnapshots.snapshot.storage.k8s.io >/dev/null 2>&1 \
  || die "VolumeSnapshot CRDs not found — unexpected on GKE. Check the cluster's GKE version."
log_ok "VolumeSnapshot CRDs present"

log_info "Applying the standard-rwo VolumeSnapshotClass and taking a snapshot of redis-cart's volume..."
kubectl apply -f "${PLATFORM_DIR}/manifests/volumesnapshotclass.yaml"
kubectl delete volumesnapshot redis-cart-snapshot -n online-boutique --ignore-not-found=true --wait=true
kubectl apply -f "${PLATFORM_DIR}/manifests/redis-cart-snapshot.yaml"

log_info "Waiting for the snapshot to become ready..."
READY=""
for _ in $(seq 1 30); do
  READY=$(kubectl get volumesnapshot redis-cart-snapshot -n online-boutique -o jsonpath='{.status.readyToUse}' 2>/dev/null)
  [[ "$READY" == "true" ]] && break
  sleep 5
done
if [[ "$READY" == "true" ]]; then
  log_ok "Snapshot redis-cart-snapshot is ready"
else
  log_warn "Snapshot not ready yet — check: kubectl describe volumesnapshot redis-cart-snapshot -n online-boutique"
fi

echo ""
echo "================================================================"
echo "  Storage ready. Prove the snapshot restores into a real,"
echo "  independent volume with:"
echo "    kubectl apply -f ${PLATFORM_DIR}/manifests/redis-cart-restore-test.template.yaml"
echo "    kubectl get pvc redis-cart-restore-test -n online-boutique -w"
echo "    kubectl delete -f ${PLATFORM_DIR}/manifests/redis-cart-restore-test.template.yaml"
echo "================================================================"
echo ""
