#!/usr/bin/env bash
# Module 13 equivalent for ACK. ACK owns the control plane, so etcd backups
# and upgrades are service operations rather than node-level lab commands.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/13-cluster-operations"
MINIO_CHART_VERSION="${MINIO_CHART_VERSION:-5.4.0}"
VELERO_CHART_VERSION="${VELERO_CHART_VERSION:-12.1.0}"
SNAPSHOT_CLASS="ack-essd-snapshot"

require_command kubectl
require_command helm
require_command jq
require_command openssl
require_config
require_storage_config
require_cluster

kubectl get namespace online-boutique >/dev/null \
  || die "Namespace online-boutique not found. Run deploy-core-workloads first."
kubectl get volumesnapshotclass "${SNAPSHOT_CLASS}" >/dev/null \
  || die "VolumeSnapshotClass ${SNAPSHOT_CLASS} not found. Run enable-storage first."

echo ""
echo "================================================================"
echo "  ACK Platform Track - Backup & Node Maintenance (Module 13)"
echo "================================================================"
echo ""
log_info "ACK manages the control plane and etcd; this track does not take a node-level etcd snapshot."
log_info "Installing an application-level Velero backup drill backed by MinIO and ACK CSI snapshots."

# Preserve the generated credentials on repeated runs. Replacing credentials
# after MinIO has initialized its data directory would disconnect Velero.
MINIO_ROOT_USER=""
MINIO_ROOT_PASSWORD=""
if helm status minio -n velero >/dev/null 2>&1; then
  minio_values="$(helm get values minio -n velero -o json)"
  MINIO_ROOT_USER="$(jq -r '.rootUser // empty' <<<"${minio_values}")"
  MINIO_ROOT_PASSWORD="$(jq -r '.rootPassword // empty' <<<"${minio_values}")"
fi
if [[ -z "${MINIO_ROOT_USER}" || -z "${MINIO_ROOT_PASSWORD}" ]]; then
  log_info "Generating MinIO root credentials..."
  MINIO_ROOT_USER="velero-$(openssl rand -hex 4)"
  MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"
fi

log_info "Installing MinIO v${MINIO_CHART_VERSION} (${ACK_STORAGE_CLASS}, ${ACK_BACKUP_DISK_SIZE})..."
helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo update minio >/dev/null
helm upgrade --install minio minio/minio \
  --version "${MINIO_CHART_VERSION}" \
  --namespace velero --create-namespace \
  -f "${PLATFORM_DIR}/manifests/minio-values.yaml" \
  --set mode=standalone \
  --set persistence.storageClass="${ACK_STORAGE_CLASS}" \
  --set persistence.size="${ACK_BACKUP_DISK_SIZE}" \
  --set rootUser="${MINIO_ROOT_USER}" \
  --set rootPassword="${MINIO_ROOT_PASSWORD}" \
  --set 'buckets[0].name=velero-backups' \
  --set 'buckets[0].policy=none' \
  --set 'buckets[0].purge=false' \
  --wait --timeout 5m
log_ok "MinIO ready"

CREDS_FILE="$(mktemp)"
trap 'rm -f "${CREDS_FILE}"' EXIT
cat >"${CREDS_FILE}" <<EOF
[default]
aws_access_key_id=${MINIO_ROOT_USER}
aws_secret_access_key=${MINIO_ROOT_PASSWORD}
EOF

log_info "Installing Velero v${VELERO_CHART_VERSION}..."
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update vmware-tanzu >/dev/null
helm upgrade --install velero vmware-tanzu/velero \
  --version "${VELERO_CHART_VERSION}" \
  --namespace velero --create-namespace \
  -f "${NATIVE_MODULE_DIR}/manifests/velero-values.yaml" \
  --set-file credentials.secretContents.cloud="${CREDS_FILE}" \
  --wait --timeout 5m
log_ok "Velero ready"

unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD minio_values

log_info "Labeling ${SNAPSHOT_CLASS} for Velero's CSI plugin..."
kubectl label volumesnapshotclass "${SNAPSHOT_CLASS}" velero.io/csi-volumesnapshot-class=true --overwrite

log_info "Waiting for the BackupStorageLocation to become Available..."
BSL_PHASE=""
for _ in $(seq 1 20); do
  BSL_PHASE="$(kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${BSL_PHASE}" == "Available" ]] && break
  sleep 5
done
[[ "${BSL_PHASE}" == "Available" ]] \
  && log_ok "BackupStorageLocation is Available" \
  || die "BackupStorageLocation phase is '${BSL_PHASE:-<none>}'. Check: kubectl describe backupstoragelocation default -n velero"

log_info "Backing up online-boutique..."
kubectl delete backup online-boutique-backup -n velero --ignore-not-found=true --wait=true >/dev/null 2>&1
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/velero-backup-online-boutique.yaml"
BACKUP_PHASE=""
for _ in $(seq 1 30); do
  BACKUP_PHASE="$(kubectl get backup online-boutique-backup -n velero -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${BACKUP_PHASE}" == "Completed" || "${BACKUP_PHASE}" == "PartiallyFailed" || "${BACKUP_PHASE}" == "Failed" ]] && break
  sleep 10
done
[[ "${BACKUP_PHASE}" == "Completed" ]] \
  || die "Backup phase is '${BACKUP_PHASE:-<none>}'. Check: kubectl describe backup online-boutique-backup -n velero"
log_ok "Backup Completed"

log_info "Restoring into online-boutique-restore-drill..."
kubectl delete namespace online-boutique-restore-drill --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
kubectl delete restore online-boutique-restore-drill -n velero --ignore-not-found=true --wait=true >/dev/null 2>&1
kubectl apply -f "${NATIVE_MODULE_DIR}/manifests/velero-restore-online-boutique.yaml"
RESTORE_PHASE=""
for _ in $(seq 1 30); do
  RESTORE_PHASE="$(kubectl get restore online-boutique-restore-drill -n velero -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${RESTORE_PHASE}" == "Completed" || "${RESTORE_PHASE}" == "PartiallyFailed" || "${RESTORE_PHASE}" == "Failed" ]] && break
  sleep 10
done
[[ "${RESTORE_PHASE}" == "Completed" ]] \
  || die "Restore phase is '${RESTORE_PHASE:-<none>}'. Check: kubectl describe restore online-boutique-restore-drill -n velero"
log_ok "Restore Completed into online-boutique-restore-drill"

ORIGINAL_DEPLOYMENTS="$(kubectl get deployments -n online-boutique --no-headers | wc -l)"
RESTORED_DEPLOYMENTS="$(kubectl get deployments -n online-boutique-restore-drill --no-headers 2>/dev/null | wc -l)"
if [[ "${RESTORED_DEPLOYMENTS}" -eq "${ORIGINAL_DEPLOYMENTS}" && "${RESTORED_DEPLOYMENTS}" -gt 0 ]]; then
  log_ok "Restore contains all ${RESTORED_DEPLOYMENTS} application Deployments"
else
  log_warn "Restore reports Completed but has ${RESTORED_DEPLOYMENTS}/${ORIGINAL_DEPLOYMENTS} Deployments. Inspect before cleanup."
fi

# A second full Online Boutique consumes material capacity. The completed
# Restore object remains as audit evidence; retain the namespace only when
# explicitly requested for manual inspection.
if [[ "${KEEP_RESTORE_DRILL:-0}" != "1" ]]; then
  log_info "Deleting online-boutique-restore-drill after validation (set KEEP_RESTORE_DRILL=1 to retain it)..."
  kubectl delete namespace online-boutique-restore-drill --ignore-not-found=true --wait=false
else
  log_warn "KEEP_RESTORE_DRILL=1 leaves a full second application copy running."
fi

log_info "Running a cordon/drain/uncordon drill on one workload-pool node..."
WORKLOAD_NODE="$(kubectl get nodes -l "${ACK_WORKLOAD_LABEL_KEY}=${ACK_WORKLOAD_LABEL_VALUE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${WORKLOAD_NODE}" ]]; then
  log_warn "No labelled workload node found; skipping the drain drill."
else
  kubectl cordon "${WORKLOAD_NODE}"
  if kubectl drain "${WORKLOAD_NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=180s; then
    log_ok "${WORKLOAD_NODE} drained; evictable Pods rescheduled elsewhere"
  else
    log_warn "Drain did not complete within the timeout; PodDisruptionBudgets or capacity may be blocking eviction."
  fi
  kubectl uncordon "${WORKLOAD_NODE}" || log_warn "Unable to uncordon ${WORKLOAD_NODE}; run: kubectl uncordon ${WORKLOAD_NODE}"
  log_ok "${WORKLOAD_NODE} is schedulable again"
fi

echo ""
echo "================================================================"
echo "  ACK Module 13 equivalent complete."
echo "  Run: bash platforms/ack/scripts/ack-track.sh verify-backup"
echo "================================================================"
