#!/usr/bin/env bash
# Creates a one-time, namespace-scoped backup and restores it into an isolated
# namespace. It never modifies the source namespace or cluster-scoped objects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/backup-center.sh"

require_backup_center

location_phase="$(kubectl get backuplocation "${ACK_BACKUP_LOCATION}" -n csdr -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "${location_phase}" == "Available" ]] \
  || die "BackupLocation ${ACK_BACKUP_LOCATION} is not Available. Run enable-backup first."
kubectl get namespace "${ACK_BACKUP_NAMESPACE}" >/dev/null \
  || die "Source namespace ${ACK_BACKUP_NAMESPACE} was not found."
if kubectl get namespace "${ACK_RESTORE_NAMESPACE}" >/dev/null 2>&1; then
  die "Restore namespace ${ACK_RESTORE_NAMESPACE} already exists. Inspect it, then run cleanup-backup-drill before creating another drill."
fi

timestamp="$(date -u +%Y%m%d%H%M%S)"
backup_name="ack-online-boutique-${timestamp}"
restore_name="${backup_name}-restore"

log_info "Creating ApplicationBackup ${backup_name} for namespace ${ACK_BACKUP_NAMESPACE}..."
render_backup_center_manifest "${BACKUP_CENTER_MANIFEST_DIR}/application-backup.yaml" "${backup_name}" "${restore_name}" | kubectl apply -f -
wait_for_backup_center_phase applicationbackup "${backup_name}"

log_info "Creating ApplicationRestore ${restore_name} into ${ACK_RESTORE_NAMESPACE}..."
render_backup_center_manifest "${BACKUP_CENTER_MANIFEST_DIR}/application-restore.yaml" "${backup_name}" "${restore_name}" | kubectl apply -f -
wait_for_backup_center_phase applicationrestore "${restore_name}"

echo ""
log_ok "Backup and isolated restore drill completed."
echo "Run: bash platforms/ack/scripts/ack-track.sh verify-backup"
echo "Then remove the drill deliberately: bash platforms/ack/scripts/ack-track.sh cleanup-backup-drill"
