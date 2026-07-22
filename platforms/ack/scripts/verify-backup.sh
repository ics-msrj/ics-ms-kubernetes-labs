#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/backup-center.sh"

PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS + 1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN + 1)); }

require_backup_center
# Verify every assertion instead of stopping at the first unavailable object.
set +e

latest_labeled_name() {
  kubectl get "$1" -n csdr -l platform.nextops.ai/backup-drill=true \
    --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -n 1 | cut -d/ -f2
}

echo ""
echo "================================================================"
echo "  ACK Backup Center - Module 13 Verification"
echo "================================================================"

echo ""
echo -e "${BLUE}--- Backup Center foundation ---${NC}"
CONTROLLER_READY="$(kubectl get deployment csdr-controller -n csdr -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[[ -n "${CONTROLLER_READY}" && "${CONTROLLER_READY}" != "0" ]] && check_pass "csdr-controller is ready" || check_fail "csdr-controller is not ready"
VELERO_READY="$(kubectl get deployment csdr-velero -n csdr -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[[ -n "${VELERO_READY}" && "${VELERO_READY}" != "0" ]] && check_pass "csdr-velero is ready" || check_fail "csdr-velero is not ready"
LOCATION_PHASE="$(kubectl get backuplocation "${ACK_BACKUP_LOCATION}" -n csdr -o jsonpath='{.status.phase}' 2>/dev/null)"
[[ "${LOCATION_PHASE}" == "Available" ]] && check_pass "BackupLocation ${ACK_BACKUP_LOCATION} is Available" || check_fail "BackupLocation phase is '${LOCATION_PHASE:-<none>}'"

echo ""
echo -e "${BLUE}--- Namespace-scoped backup drill ---${NC}"
BACKUP_NAME="$(latest_labeled_name applicationbackup)"
if [[ -z "${BACKUP_NAME}" ]]; then
  check_fail "No ACK Platform Track ApplicationBackup exists; run run-backup-drill"
else
  BACKUP_PHASE="$(kubectl get applicationbackup "${BACKUP_NAME}" -n csdr -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "${BACKUP_PHASE}" == "Completed" ]] && check_pass "ApplicationBackup ${BACKUP_NAME}: Completed" || check_fail "ApplicationBackup ${BACKUP_NAME} phase is '${BACKUP_PHASE:-<none>}'"
fi

RESTORE_NAME="$(latest_labeled_name applicationrestore)"
if [[ -z "${RESTORE_NAME}" ]]; then
  check_fail "No ACK Platform Track ApplicationRestore exists; run run-backup-drill"
else
  RESTORE_PHASE="$(kubectl get applicationrestore "${RESTORE_NAME}" -n csdr -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "${RESTORE_PHASE}" == "Completed" ]] && check_pass "ApplicationRestore ${RESTORE_NAME}: Completed" || check_fail "ApplicationRestore ${RESTORE_NAME} phase is '${RESTORE_PHASE:-<none>}'"
fi

if kubectl get namespace "${ACK_RESTORE_NAMESPACE}" >/dev/null 2>&1; then
  SOURCE_DEPLOYMENTS="$(kubectl get deployments -n "${ACK_BACKUP_NAMESPACE}" --no-headers 2>/dev/null | wc -l)"
  RESTORED_DEPLOYMENTS="$(kubectl get deployments -n "${ACK_RESTORE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)"
  if [[ "${SOURCE_DEPLOYMENTS}" -gt 0 && "${SOURCE_DEPLOYMENTS}" -eq "${RESTORED_DEPLOYMENTS}" ]]; then
    check_pass "Restore namespace contains all ${RESTORED_DEPLOYMENTS} source Deployments"
  else
    check_fail "Restore namespace has ${RESTORED_DEPLOYMENTS}/${SOURCE_DEPLOYMENTS} source Deployments"
  fi

  RESTORED_PVC_COUNT="$(kubectl get pvc -n "${ACK_RESTORE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)"
  [[ "${RESTORED_PVC_COUNT}" -ge 1 ]] && check_pass "Restore namespace has ${RESTORED_PVC_COUNT} PVC(s)" || check_fail "Restore namespace has no PVCs"
else
  check_fail "Restore namespace ${ACK_RESTORE_NAMESPACE} was not created"
fi

echo ""
echo "================================================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo -e "${RED}  ACK Module 13 is not complete.${NC}"
  exit 1
fi

echo -e "${GREEN}  ACK Module 13 complete.${NC}"
