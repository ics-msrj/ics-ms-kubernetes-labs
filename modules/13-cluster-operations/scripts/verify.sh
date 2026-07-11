#!/bin/bash
# =============================================================================
# Module 13 — Cluster Operations — verify.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUPS_DIR="${MODULE_DIR}/backups"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 13 — Cluster Operations Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- etcd backup ---${NC}"
SNAPSHOT_COUNT=$(find "$BACKUPS_DIR" -name "etcd-snapshot-*.db" -size +0c 2>/dev/null | wc -l)
if [[ "$SNAPSHOT_COUNT" -ge 1 ]]; then
  LATEST=$(find "$BACKUPS_DIR" -name "etcd-snapshot-*.db" -size +0c 2>/dev/null | sort | tail -1)
  check_pass "etcd snapshot exists off-node ($(basename "$LATEST"), $(du -h "$LATEST" | cut -f1))"
else
  check_fail "No non-empty etcd snapshot found in ${BACKUPS_DIR}"
fi

echo ""
echo -e "${BLUE}--- MinIO + Velero ---${NC}"
MINIO_READY=$(kubectl get pods -n velero -l app=minio --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[[ "$MINIO_READY" -ge 1 ]] && check_pass "MinIO is Running" || check_fail "MinIO is not Running"

VELERO_READY=$(kubectl get deployment velero -n velero -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$VELERO_READY" && "$VELERO_READY" != "0" ]] && check_pass "Velero is ready" || check_fail "Velero is not ready"

BSL_PHASE=$(kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
[[ "$BSL_PHASE" == "Available" ]] && check_pass "BackupStorageLocation is Available" || check_fail "BackupStorageLocation phase is '${BSL_PHASE:-<none>}'"

SNAP_CLASS_LABEL=$(kubectl get volumesnapshotclass longhorn -o jsonpath='{.metadata.labels.velero\.io/csi-volumesnapshot-class}' 2>/dev/null)
[[ "$SNAP_CLASS_LABEL" == "true" ]] && check_pass "VolumeSnapshotClass longhorn labeled for Velero's CSI plugin" || check_fail "VolumeSnapshotClass missing the velero.io/csi-volumesnapshot-class label"

echo ""
echo -e "${BLUE}--- Backup & restore drill ---${NC}"
BACKUP_PHASE=$(kubectl get backup online-boutique-backup -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
[[ "$BACKUP_PHASE" == "Completed" ]] && check_pass "Backup online-boutique-backup: Completed" || check_fail "Backup phase is '${BACKUP_PHASE:-<none>}'"

RESTORE_PHASE=$(kubectl get restore online-boutique-restore-drill -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
[[ "$RESTORE_PHASE" == "Completed" ]] && check_pass "Restore online-boutique-restore-drill: Completed" || check_fail "Restore phase is '${RESTORE_PHASE:-<none>}'"

if kubectl get namespace online-boutique-restore-drill &>/dev/null; then
  RESTORED_DEPLOYMENTS=$(kubectl get deployments -n online-boutique-restore-drill --no-headers 2>/dev/null | wc -l)
  ORIGINAL_DEPLOYMENTS=$(kubectl get deployments -n online-boutique --no-headers 2>/dev/null | wc -l)
  if [[ "$RESTORED_DEPLOYMENTS" -ge 1 && "$RESTORED_DEPLOYMENTS" -eq "$ORIGINAL_DEPLOYMENTS" ]]; then
    check_pass "online-boutique-restore-drill has all ${RESTORED_DEPLOYMENTS} Deployments the original namespace has — this is a real, verified restore, not just a Completed status"
  else
    check_fail "online-boutique-restore-drill has ${RESTORED_DEPLOYMENTS} Deployments, original has ${ORIGINAL_DEPLOYMENTS}"
  fi
else
  check_fail "Namespace online-boutique-restore-drill was not created"
fi

echo ""
echo -e "${BLUE}--- Node maintenance ---${NC}"
UNSCHEDULABLE=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "SchedulingDisabled" || true)
[[ "$UNSCHEDULABLE" -eq 0 ]] && check_pass "All nodes schedulable — the drain drill left no node cordoned" || check_fail "${UNSCHEDULABLE} node(s) still cordoned — check: kubectl get nodes"

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 13 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 13 complete!${NC}"
  echo -e "    Next: cat modules/14-multi-cluster-mgmt/README.md"
  echo ""
  exit 0
fi
