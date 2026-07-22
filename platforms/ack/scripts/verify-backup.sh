#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

SNAPSHOT_CLASS="ack-essd-snapshot"
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS + 1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN + 1)); }

require_command kubectl
require_config
require_storage_config
require_cluster

# common.sh enables errexit for setup scripts. A verifier must continue after
# an unavailable object so it can report every failed assertion instead.
set +e

echo ""
echo "================================================================"
echo "  ACK Platform Track - Module 13 Verification"
echo "================================================================"

echo ""
echo -e "${BLUE}--- Managed control plane ---${NC}"
check_pass "ACK manages control-plane and etcd backup; no node-level etcd snapshot is expected"

echo ""
echo -e "${BLUE}--- MinIO + Velero ---${NC}"
MINIO_READY="$(kubectl get pods -n velero -l app=minio --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
[[ "${MINIO_READY}" -ge 1 ]] && check_pass "MinIO is Running" || check_fail "MinIO is not Running"

VELERO_READY="$(kubectl get deployment velero -n velero -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[[ -n "${VELERO_READY}" && "${VELERO_READY}" != "0" ]] && check_pass "Velero is ready" || check_fail "Velero is not ready"

BSL_PHASE="$(kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}' 2>/dev/null)"
[[ "${BSL_PHASE}" == "Available" ]] && check_pass "BackupStorageLocation is Available" || check_fail "BackupStorageLocation phase is '${BSL_PHASE:-<none>}'"

SNAP_CLASS_LABEL="$(kubectl get volumesnapshotclass "${SNAPSHOT_CLASS}" -o jsonpath='{.metadata.labels.velero\.io/csi-volumesnapshot-class}' 2>/dev/null)"
[[ "${SNAP_CLASS_LABEL}" == "true" ]] && check_pass "VolumeSnapshotClass ${SNAPSHOT_CLASS} is labeled for Velero CSI" || check_fail "VolumeSnapshotClass ${SNAPSHOT_CLASS} is not labeled for Velero CSI"

echo ""
echo -e "${BLUE}--- Backup & restore drill ---${NC}"
BACKUP_PHASE="$(kubectl get backup online-boutique-backup -n velero -o jsonpath='{.status.phase}' 2>/dev/null)"
[[ "${BACKUP_PHASE}" == "Completed" ]] && check_pass "Backup online-boutique-backup: Completed" || check_fail "Backup phase is '${BACKUP_PHASE:-<none>}'"

RESTORE_PHASE="$(kubectl get restore online-boutique-restore-drill -n velero -o jsonpath='{.status.phase}' 2>/dev/null)"
[[ "${RESTORE_PHASE}" == "Completed" ]] && check_pass "Restore online-boutique-restore-drill: Completed" || check_fail "Restore phase is '${RESTORE_PHASE:-<none>}'"

if kubectl get namespace online-boutique-restore-drill >/dev/null 2>&1; then
  RESTORED_DEPLOYMENTS="$(kubectl get deployments -n online-boutique-restore-drill --no-headers 2>/dev/null | wc -l)"
  ORIGINAL_DEPLOYMENTS="$(kubectl get deployments -n online-boutique --no-headers 2>/dev/null | wc -l)"
  if [[ "${RESTORED_DEPLOYMENTS}" -gt 0 && "${RESTORED_DEPLOYMENTS}" -eq "${ORIGINAL_DEPLOYMENTS}" ]]; then
    check_pass "Restore namespace contains all ${RESTORED_DEPLOYMENTS} original Deployments"
  else
    check_fail "Restore namespace has ${RESTORED_DEPLOYMENTS}/${ORIGINAL_DEPLOYMENTS} Deployments"
  fi
else
  if [[ "${RESTORE_PHASE}" == "Completed" ]]; then
    check_pass "Restore namespace was cleaned up after the completed drill"
  else
    check_warn "Restore namespace is absent because the restore has not completed"
  fi
fi

echo ""
echo -e "${BLUE}--- Node maintenance ---${NC}"
UNSCHEDULABLE="$(kubectl get nodes --no-headers 2>/dev/null | grep -c 'SchedulingDisabled' || true)"
[[ "${UNSCHEDULABLE}" -eq 0 ]] && check_pass "All nodes are schedulable" || check_fail "${UNSCHEDULABLE} node(s) remain cordoned"

echo ""
echo "================================================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo -e "${RED}  ACK Module 13 is not complete.${NC}"
  exit 1
fi

echo -e "${GREEN}  ACK Module 13 complete.${NC}"
