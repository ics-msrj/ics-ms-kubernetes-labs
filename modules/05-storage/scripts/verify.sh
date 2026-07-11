#!/bin/bash
# =============================================================================
# Module 05 — Storage — verify.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 05 — Storage Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- VolumeSnapshot support ---${NC}"
if kubectl get crd volumesnapshots.snapshot.storage.k8s.io &>/dev/null; then
  check_pass "VolumeSnapshot CRDs installed"
else
  check_fail "VolumeSnapshot CRDs not found"
fi
SNAP_CTRL_READY=$(kubectl get deployment snapshot-controller -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [[ -n "$SNAP_CTRL_READY" && "$SNAP_CTRL_READY" != "0" ]]; then
  check_pass "snapshot-controller is ready"
else
  check_fail "snapshot-controller is not ready"
fi

echo ""
echo -e "${BLUE}--- Longhorn ---${NC}"
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
LH_READY=$(kubectl get daemonset longhorn-manager -n longhorn-system -o jsonpath='{.status.numberReady}' 2>/dev/null)
if [[ -n "$LH_READY" && "$LH_READY" == "$NODE_COUNT" ]]; then
  check_pass "longhorn-manager: ${LH_READY}/${NODE_COUNT} nodes"
else
  check_fail "longhorn-manager: ${LH_READY:-0}/${NODE_COUNT} nodes ready"
fi

EXPANDABLE=$(kubectl get storageclass longhorn -o jsonpath='{.allowVolumeExpansion}' 2>/dev/null)
if [[ "$EXPANDABLE" == "true" ]]; then
  check_pass "StorageClass longhorn exists and allows volume expansion"
else
  check_fail "StorageClass longhorn missing or allowVolumeExpansion != true"
fi

echo ""
echo -e "${BLUE}--- redis-cart migrated to Longhorn ---${NC}"
PVC_SC=$(kubectl get pvc redis-data-redis-cart-0 -n online-boutique -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
PVC_PHASE=$(kubectl get pvc redis-data-redis-cart-0 -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "$PVC_SC" == "longhorn" && "$PVC_PHASE" == "Bound" ]]; then
  check_pass "redis-data-redis-cart-0 is Bound on StorageClass longhorn"
else
  check_fail "redis-data-redis-cart-0: storageClass=${PVC_SC:-<none>} phase=${PVC_PHASE:-<none>} (expected longhorn/Bound)"
fi

STS_READY=$(kubectl get statefulset redis-cart -n online-boutique -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [[ "$STS_READY" == "1" ]]; then
  check_pass "redis-cart StatefulSet: 1/1 ready"
else
  check_fail "redis-cart StatefulSet: ${STS_READY:-0}/1 ready"
fi

echo ""
echo -e "${BLUE}--- Snapshot + restore ---${NC}"
SNAP_READY=$(kubectl get volumesnapshot redis-cart-snapshot -n online-boutique -o jsonpath='{.status.readyToUse}' 2>/dev/null)
if [[ "$SNAP_READY" == "true" ]]; then
  check_pass "VolumeSnapshot redis-cart-snapshot is readyToUse"
else
  check_fail "VolumeSnapshot redis-cart-snapshot not ready (got '${SNAP_READY:-<none>}')"
fi

log_restore_cleanup() {
  kubectl delete pvc redis-cart-restore-test -n online-boutique --ignore-not-found=true --wait=false &>/dev/null
}
trap log_restore_cleanup EXIT

if [[ "$SNAP_READY" == "true" ]]; then
  kubectl apply -f "${MODULE_DIR}/manifests/redis-cart-restore-test.template.yaml" &>/dev/null
  RESTORE_BOUND=""
  for i in $(seq 1 24); do
    RESTORE_BOUND=$(kubectl get pvc redis-cart-restore-test -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$RESTORE_BOUND" == "Bound" ]] && break
    sleep 5
  done
  if [[ "$RESTORE_BOUND" == "Bound" ]]; then
    check_pass "Restored a new PVC from the snapshot successfully (redis-cart-restore-test: Bound)"
  else
    check_fail "Restoring from the snapshot did not reach Bound (got '${RESTORE_BOUND:-<none>}')"
  fi
else
  check_warn "Skipping restore test — snapshot isn't ready"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 05 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 05 complete!${NC}"
  echo -e "    Next: cat modules/06-security-policy/README.md"
  echo ""
  exit 0
fi
