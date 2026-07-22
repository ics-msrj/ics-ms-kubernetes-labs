#!/usr/bin/env bash
# Registers the immutable ACK Backup Center vault. It does not run a backup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/backup-center.sh"

require_backup_center

kubectl get namespace "${ACK_BACKUP_NAMESPACE}" >/dev/null \
  || die "Namespace ${ACK_BACKUP_NAMESPACE} was not found."

echo ""
echo "================================================================"
echo "  ACK Backup Center - Module 13 Foundation"
echo "================================================================"
echo ""

if kubectl get backuplocation "${ACK_BACKUP_LOCATION}" -n csdr >/dev/null 2>&1; then
  current_bucket="$(kubectl get backuplocation "${ACK_BACKUP_LOCATION}" -n csdr -o jsonpath='{.spec.objectStorage.bucket}')"
  current_prefix="$(kubectl get backuplocation "${ACK_BACKUP_LOCATION}" -n csdr -o jsonpath='{.spec.objectStorage.prefix}')"
  current_region="$(kubectl get backuplocation "${ACK_BACKUP_LOCATION}" -n csdr -o jsonpath='{.spec.config.region}')"
  [[ "${current_bucket}" == "${ACK_BACKUP_BUCKET}" && "${current_prefix}" == "${ACK_BACKUP_PREFIX}" && "${current_region}" == "${ACK_REGION}" ]] \
    || die "BackupLocation ${ACK_BACKUP_LOCATION} already exists with different bucket, prefix, or region. Backup vaults are shared and must not be changed in place."
  log_ok "Existing BackupLocation ${ACK_BACKUP_LOCATION} matches ACK configuration"
else
  log_info "Registering OSS bucket ${ACK_BACKUP_BUCKET} as BackupLocation ${ACK_BACKUP_LOCATION}..."
  render_backup_center_manifest "${BACKUP_CENTER_MANIFEST_DIR}/backuplocation.yaml" | kubectl apply -f -
fi

phase=""
for _ in $(seq 1 60); do
  phase="$(kubectl get backuplocation "${ACK_BACKUP_LOCATION}" -n csdr -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${phase}" == "Available" ]] && break
  sleep 5
done
[[ "${phase}" == "Available" ]] \
  || die "BackupLocation ${ACK_BACKUP_LOCATION} phase is '${phase:-<none>}'. Run: kubectl describe backuplocation ${ACK_BACKUP_LOCATION} -n csdr"

log_ok "BackupLocation ${ACK_BACKUP_LOCATION} is Available"
echo ""
echo "Next: bash platforms/ack/scripts/ack-track.sh run-backup-drill"
