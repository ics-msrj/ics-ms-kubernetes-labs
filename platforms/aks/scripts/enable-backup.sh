#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — enable-backup.sh (Module 13 equivalent)
#
# Two distinct modes:
#   AKS_ENABLE_AKS_BACKUP=1  -> Azure Backup for AKS (Backup Vault, Backup
#                               Extension, Trusted Access — all provisioned
#                               by terraform/backup.tf with
#                               enable_aks_backup=true). This script then
#                               only triggers and verifies an on-demand
#                               backup — the scheduled policy, extension
#                               install, and RBAC are all Terraform's job.
#   (default)                 -> Velero+MinIO, same mechanism as native
#                               Module 13, reused unmodified except the
#                               storage class.
#
# Either way: no etcd snapshot step — AKS owns and backs up its own control
# plane, there's no static pod to exec into. The node maintenance drill at
# the end is shared by both modes and always runs.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

NATIVE_MODULE_DIR="${REPO_ROOT}/modules/13-cluster-operations"
MINIO_CHART_VERSION="${MINIO_CHART_VERSION:-5.4.0}"
VELERO_CHART_VERSION="${VELERO_CHART_VERSION:-12.1.0}"
AKS_ENABLE_AKS_BACKUP="${AKS_ENABLE_AKS_BACKUP:-0}"
AKS_BACKUP_RESOURCE_GROUP="${AKS_BACKUP_RESOURCE_GROUP:-}"
AKS_BACKUP_VAULT_NAME="${AKS_BACKUP_VAULT_NAME:-}"

require_command kubectl
require_cluster
kubectl get namespace online-boutique >/dev/null || die "Namespace online-boutique not found. Run deploy-core-workloads first."

echo ""
echo "================================================================"
echo "  AKS Platform Track — Backup & Node Maintenance (Module 13 equivalent)"
echo "================================================================"
echo ""
log_info "AKS backs up and manages its own control plane / etcd — there is no"
log_info "equivalent to Module 13's etcd snapshot step here."
echo ""

if [[ "${AKS_ENABLE_AKS_BACKUP}" == "1" ]]; then
  require_command az
  [[ -n "${AKS_BACKUP_RESOURCE_GROUP}" && -n "${AKS_BACKUP_VAULT_NAME}" ]] \
    || die "AKS_BACKUP_RESOURCE_GROUP and AKS_BACKUP_VAULT_NAME must be set in aks.env when AKS_ENABLE_AKS_BACKUP=1 (terraform output backup_resource_group_name / backup_vault_name)."

  log_info "Using Azure Backup for AKS (Backup Vault: ${AKS_BACKUP_VAULT_NAME})..."
  BACKUP_INSTANCE_NAME="aks-backup-instance"

  log_info "Confirming the backup extension is running in-cluster..."
  kubectl get pods -n dataprotection-microsoft >/dev/null 2>&1 \
    || die "dataprotection-microsoft namespace not found — the Backup Extension isn't installed. Run terraform apply with enable_aks_backup=true first."
  kubectl wait --for=condition=Ready pods --all -n dataprotection-microsoft --timeout=180s \
    || log_warn "Not every backup extension Pod is Ready yet — the on-demand backup below may fail if it isn't up in time."

  log_info "Triggering an on-demand backup..."
  # "Default" (the retention rule from terraform's default_retention_rule)
  # is not a triggerable rule — BMSUserErrorDPPAdhocBackupNotAllowedForBackupType
  # if used here. "BackupIntervals" is the actual backup-schedule rule
  # implicitly named from backup_repeating_time_intervals; confirm with
  # `az dataprotection backup-policy show ... --query
  # "properties.policyRules[].name"` if this ever changes.
  az dataprotection backup-instance adhoc-backup \
    --name "${BACKUP_INSTANCE_NAME}" \
    --rule-name "BackupIntervals" \
    --resource-group "${AKS_BACKUP_RESOURCE_GROUP}" \
    --vault-name "${AKS_BACKUP_VAULT_NAME}" \
    --query "jobId" -o tsv > /tmp/aks-backup-job-id.txt 2>&1 \
    || die "Failed to trigger the on-demand backup — check: cat /tmp/aks-backup-job-id.txt"
  JOB_ID="$(cat /tmp/aks-backup-job-id.txt)"
  rm -f /tmp/aks-backup-job-id.txt

  log_info "Waiting for backup job to complete (this can take several minutes)..."
  JOB_STATUS=""
  for _ in $(seq 1 60); do
    JOB_STATUS=$(az dataprotection job show --ids "${JOB_ID}" --query "properties.status" -o tsv 2>/dev/null)
    [[ "$JOB_STATUS" == "Completed" || "$JOB_STATUS" == "Failed" || "$JOB_STATUS" == "CompletedWithWarnings" ]] && break
    sleep 15
  done
  case "$JOB_STATUS" in
    Completed) log_ok "Backup Completed" ;;
    CompletedWithWarnings) log_warn "Backup Completed With Warnings — check: az dataprotection job show --ids ${JOB_ID}" ;;
    *) die "Backup job status is '${JOB_STATUS:-<none>}' — check: az dataprotection job show --ids ${JOB_ID}" ;;
  esac

  echo ""
  log_info "Restore is not scripted here — Azure Backup for AKS restores into"
  log_info "a fresh namespace via a restore configuration file, not a single"
  log_info "CLI flag. To restore manually:"
  log_info "  https://learn.microsoft.com/azure/backup/azure-kubernetes-service-cluster-restore"
else
  log_info "Using Velero+MinIO (application-level backup, same mechanism as native Module 13)."
  kubectl get volumesnapshotclass managed-csi >/dev/null 2>&1 || die "VolumeSnapshotClass managed-csi not found. Run enable-storage.sh first."
  require_command helm

  log_info "Generating MinIO root credentials..."
  MINIO_ROOT_USER="velero-$(openssl rand -hex 4)"
  MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"

  log_info "Installing MinIO v${MINIO_CHART_VERSION} (standalone, ${AKS_STORAGE_CLASS}-backed)..."
  # resources.requests.memory=256Mi overrides the chart's own default of
  # 16Gi — appropriate for a real production MinIO, but unschedulable on
  # this lab's node sizes and wildly oversized for a lab backup target.
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
    --set resources.requests.memory=256Mi \
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

  # The drill namespace is a full second copy of online-boutique — same CPU
  # requests as the real thing, ~2.7 cores in this repo's default sizing.
  # Left running, it silently eats capacity that later Pods (or the drain
  # drill right below) then can't schedule into, with no obvious link back
  # to "there's a leftover restore namespace" in the resulting error. The
  # Restore object's own .status.phase (checked above) is proof enough that
  # restore works — the live namespace doesn't need to stick around too.
  # Set KEEP_RESTORE_DRILL=1 to skip this and inspect it manually instead.
  if [[ "${KEEP_RESTORE_DRILL:-0}" != "1" ]]; then
    log_info "Deleting online-boutique-restore-drill (it's a full second copy of the app — set KEEP_RESTORE_DRILL=1 to keep it for inspection instead)..."
    kubectl delete namespace online-boutique-restore-drill --ignore-not-found=true --wait=false
  else
    log_warn "KEEP_RESTORE_DRILL=1 — online-boutique-restore-drill left running, consuming CPU/memory equal to a second full app copy."
  fi
fi

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
if [[ "${AKS_ENABLE_AKS_BACKUP}" != "1" ]]; then
  echo "  MinIO console: kubectl port-forward -n velero svc/minio-console 9001:9001"
fi
echo "  AKS control-plane/etcd backup and version upgrades are Azure's"
echo "  own operations (az aks show, az aks get-upgrades, az aks upgrade)"
echo "  — not something this track scripts, same reasoning as Module 13's"
echo "  own deliberately-manual kubeadm upgrade and etcd restore."
echo "================================================================"
echo ""
