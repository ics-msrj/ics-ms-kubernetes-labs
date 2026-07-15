#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — enable-backup.sh (Module 13 equivalent)
#
# Module 13's etcd snapshot step has no AKS equivalent at all — there is
# no etcd static pod to exec into, because AKS owns and backs up the
# control plane itself. Everything else in Module 13 turned out to have
# zero Longhorn-specific content once actually checked: velero-values.yaml
# and both the Backup/Restore manifests reference nothing but MinIO (S3
# API) and the VolumeSnapshot CRDs generically — they're reused here
# completely unmodified. Only MinIO's own storage class and the
# VolumeSnapshotClass label need to swap from longhorn to managed-csi.
#
# The node maintenance drill is also reused, with one AKS-specific
# addition: it only ever selects a workload-pool node, never the system
# pool, so this drill can't disrupt AKS's own components.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/13-cluster-operations"
MINIO_CHART_VERSION="${MINIO_CHART_VERSION:-5.4.0}"
VELERO_CHART_VERSION="${VELERO_CHART_VERSION:-12.1.0}"

require_command kubectl
require_command helm
require_cluster
kubectl get namespace online-boutique >/dev/null || die "Namespace online-boutique not found. Run deploy-core-workloads first."
kubectl get volumesnapshotclass managed-csi >/dev/null 2>&1 || die "VolumeSnapshotClass managed-csi not found. Run enable-storage.sh first."

echo ""
echo "================================================================"
echo "  AKS Platform Track — Backup & Node Maintenance (Module 13 equivalent)"
echo "================================================================"
echo ""
log_info "AKS backs up and manages its own control plane / etcd — there is no"
log_info "equivalent to Module 13's etcd snapshot step here. What follows is"
log_info "application-level backup (Velero) and a node maintenance drill,"
log_info "same as the native track."
echo ""

log_info "Generating MinIO root credentials..."
MINIO_ROOT_USER="velero-$(openssl rand -hex 4)"
MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"

log_info "Installing MinIO v${MINIO_CHART_VERSION} (standalone, ${AKS_STORAGE_CLASS}-backed)..."
helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo update minio >/dev/null
helm upgrade --install minio minio/minio \
  --version "${MINIO_CHART_VERSION}" \
  --namespace velero --create-namespace \
  --set mode=standalone \
  --set persistence.storageClass="${AKS_STORAGE_CLASS}" \
  --set persistence.size=10Gi \
  --set rootUser="${MINIO_ROOT_USER}" \
  --set rootPassword="${MINIO_ROOT_PASSWORD}" \
  --set 'buckets[0].name=velero-backups' \
  --set 'buckets[0].policy=none' \
  --set 'buckets[0].purge=false' \
  --wait --timeout 5m
log_ok "MinIO ready"

log_info "Installing Velero v${VELERO_CHART_VERSION} (velero-values.yaml reused unmodified from Module 13)..."
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update vmware-tanzu >/dev/null
CREDS_FILE="$(mktemp)"
cat > "$CREDS_FILE" <<EOF
[default]
aws_access_key_id=${MINIO_ROOT_USER}
aws_secret_access_key=${MINIO_ROOT_PASSWORD}
EOF
helm upgrade --install velero vmware-tanzu/velero \
  --version "${VELERO_CHART_VERSION}" \
  --namespace velero --create-namespace \
  -f "${NATIVE_MODULE_DIR}/manifests/velero-values.yaml" \
  --set-file credentials.secretContents.cloud="${CREDS_FILE}" \
  --wait --timeout 5m
rm -f "$CREDS_FILE"
unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
log_ok "Velero ready"

log_info "Labeling the managed-csi VolumeSnapshotClass for Velero's CSI plugin..."
kubectl label volumesnapshotclass managed-csi velero.io/csi-volumesnapshot-class=true --overwrite

log_info "Waiting for the BackupStorageLocation to become Available..."
BSL_PHASE=""
for _ in $(seq 1 20); do
  BSL_PHASE=$(kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$BSL_PHASE" == "Available" ]] && break
  sleep 5
done
[[ "$BSL_PHASE" == "Available" ]] \
  && log_ok "BackupStorageLocation is Available" \
  || log_warn "BackupStorageLocation phase is '${BSL_PHASE:-<none>}' — check: kubectl describe backupstoragelocation default -n velero"

log_info "Backing up online-boutique (manifests reused unmodified from Module 13)..."
kubectl delete backup online-boutique-backup -n velero --ignore-not-found=true --wait=true >/dev/null 2>&1
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/velero-backup-online-boutique.yaml"
BACKUP_PHASE=""
for _ in $(seq 1 30); do
  BACKUP_PHASE=$(kubectl get backup online-boutique-backup -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$BACKUP_PHASE" == "Completed" || "$BACKUP_PHASE" == "PartiallyFailed" || "$BACKUP_PHASE" == "Failed" ]] && break
  sleep 10
done
if [[ "$BACKUP_PHASE" == "Completed" ]]; then
  log_ok "Backup Completed"
else
  die "Backup phase is '${BACKUP_PHASE:-<none>}' — check: kubectl describe backup online-boutique-backup -n velero"
fi

log_info "Restoring into online-boutique-restore-drill..."
kubectl delete restore online-boutique-restore-drill -n velero --ignore-not-found=true --wait=true >/dev/null 2>&1
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/velero-restore-online-boutique.yaml"
RESTORE_PHASE=""
for _ in $(seq 1 30); do
  RESTORE_PHASE=$(kubectl get restore online-boutique-restore-drill -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$RESTORE_PHASE" == "Completed" || "$RESTORE_PHASE" == "PartiallyFailed" || "$RESTORE_PHASE" == "Failed" ]] && break
  sleep 10
done
[[ "$RESTORE_PHASE" == "Completed" ]] \
  && log_ok "Restore Completed into online-boutique-restore-drill" \
  || log_warn "Restore phase is '${RESTORE_PHASE:-<none>}' — check: kubectl describe restore online-boutique-restore-drill -n velero"

log_info "Running a cordon/drain/uncordon drill on one WORKLOAD-pool node (never the system pool)..."
WORKLOAD_NODE=$(kubectl get nodes -l "${AKS_WORKLOAD_LABEL_KEY}=${AKS_WORKLOAD_LABEL_VALUE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$WORKLOAD_NODE" ]]; then
  log_warn "No labelled workload node found — skipping the drain drill."
else
  log_info "Cordoning ${WORKLOAD_NODE}..."
  kubectl cordon "$WORKLOAD_NODE"
  log_info "Draining ${WORKLOAD_NODE} (respects PodDisruptionBudgets from Module 07)..."
  kubectl drain "$WORKLOAD_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=180s
  log_ok "${WORKLOAD_NODE} drained — every evictable pod rescheduled elsewhere"
  log_info "Uncordoning ${WORKLOAD_NODE}..."
  kubectl uncordon "$WORKLOAD_NODE"
  log_ok "${WORKLOAD_NODE} schedulable again"
fi

echo ""
echo "================================================================"
echo "  Backup & node maintenance ready."
echo "  MinIO console: kubectl port-forward -n velero svc/minio-console 9001:9001"
echo "  AKS control-plane/etcd backup and version upgrades are Azure's"
echo "  own operations (az aks show, az aks get-upgrades, az aks upgrade)"
echo "  — not something this track scripts, same reasoning as Module 13's"
echo "  own deliberately-manual kubeadm upgrade and etcd restore."
echo "================================================================"
echo ""
