#!/usr/bin/env bash
# Deletes only ACK Platform Track drill tasks by using Backup Center's
# DeleteRequest API, then removes the isolated restore namespace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/backup-center.sh"

require_backup_center

echo "This removes ACK Platform Track ApplicationBackup/ApplicationRestore drill data"
echo "and namespace ${ACK_RESTORE_NAMESPACE}. It does not remove BackupLocation ${ACK_BACKUP_LOCATION}."
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

create_delete_request() {
  local object_name="$1"
  local object_type="$2"
  kubectl apply -f - <<EOF
apiVersion: csdr.alibabacloud.com/v1beta1
kind: DeleteRequest
metadata:
  name: ${object_name}-dbr
  namespace: csdr
spec:
  deleteObjectName: ${object_name}
  deleteObjectType: ${object_type}
EOF
}

kubectl delete namespace "${ACK_RESTORE_NAMESPACE}" --ignore-not-found=true --wait=true

for restore_name in $(kubectl get applicationrestore -n csdr -l platform.nextops.ai/backup-drill=true -o jsonpath='{.items[*].metadata.name}'); do
  create_delete_request "${restore_name}" Restore
done
for backup_name in $(kubectl get applicationbackup -n csdr -l platform.nextops.ai/backup-drill=true -o jsonpath='{.items[*].metadata.name}'); do
  create_delete_request "${backup_name}" Backup
done

log_ok "DeleteRequest resources submitted. Check: kubectl get deleterequest -n csdr"
