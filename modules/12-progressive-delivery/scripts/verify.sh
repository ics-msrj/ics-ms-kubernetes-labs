#!/bin/bash
# =============================================================================
# Module 12 — Progressive Delivery — verify.sh
#
# Doesn't just check the Rollout objects exist — triggers a real new
# revision on each and watches the actual behavior: frontend should
# progress through its canary steps (with a real AnalysisRun) and return to
# Healthy; productcatalogservice should stage a preview and PAUSE rather
# than cut over on its own. Expect this to take a few minutes — the canary
# steps include two real 60s pauses.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 12 — Progressive Delivery Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Argo Rollouts controller ---${NC}"
CTRL_READY=$(kubectl get deployment argo-rollouts -n argo-rollouts -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$CTRL_READY" && "$CTRL_READY" != "0" ]] && check_pass "argo-rollouts controller is ready" || check_fail "argo-rollouts controller is not ready"

echo ""
echo -e "${BLUE}--- Static configuration ---${NC}"
kubectl get rollout frontend -n online-boutique &>/dev/null \
  && check_pass "frontend is a Rollout" || check_fail "frontend Rollout not found"
kubectl get analysistemplate frontend-no-restarts -n online-boutique &>/dev/null \
  && check_pass "AnalysisTemplate frontend-no-restarts exists" || check_fail "AnalysisTemplate not found"
HPA_KIND=$(kubectl get hpa frontend -n online-boutique -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)
[[ "$HPA_KIND" == "Rollout" ]] && check_pass "HPA frontend retargeted at kind: Rollout" || check_fail "HPA frontend scaleTargetRef.kind is '${HPA_KIND:-<none>}', expected Rollout"
kubectl get rollout productcatalogservice -n online-boutique &>/dev/null \
  && check_pass "productcatalogservice is a Rollout" || check_fail "productcatalogservice Rollout not found"
kubectl get svc productcatalogservice-preview -n online-boutique &>/dev/null \
  && check_pass "productcatalogservice-preview Service exists" || check_fail "preview Service not found"

echo ""
echo -e "${BLUE}--- Live canary progression (frontend) ---${NC}"
kubectl patch rollout frontend -n online-boutique --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"verify-run\":\"$(date +%s)\"}}}}}" &>/dev/null

PROGRESSED=""
for i in $(seq 1 12); do
  PHASE=$(kubectl get rollout frontend -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$PHASE" == "Progressing" ]] && { PROGRESSED="yes"; break; }
  sleep 5
done
[[ "$PROGRESSED" == "yes" ]] \
  && check_pass "Rollout entered Progressing after a template change" \
  || check_warn "Rollout didn't show Progressing within 60s — it may have already finished; checking final state below"

log_info_wait_healthy() {
  for i in $(seq 1 36); do
    local phase
    phase=$(kubectl get rollout frontend -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$phase" == "Healthy" ]] && return 0
    sleep 10
  done
  return 1
}
if log_info_wait_healthy; then
  check_pass "frontend Rollout completed its canary steps and returned to Healthy"
else
  check_fail "frontend Rollout did not reach Healthy within 6 minutes — check: kubectl argo rollouts get rollout frontend -n online-boutique (or kubectl describe rollout)"
fi

ANALYSIS_RESULT=$(kubectl get analysisrun -n online-boutique -l rollout-name=frontend --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)
if [[ "$ANALYSIS_RESULT" == "Successful" ]]; then
  check_pass "The AnalysisRun this canary triggered was Successful"
elif [[ -n "$ANALYSIS_RESULT" ]]; then
  check_warn "Most recent AnalysisRun phase is '${ANALYSIS_RESULT}' — check: kubectl get analysisrun -n online-boutique"
else
  check_warn "No AnalysisRun found yet for this run"
fi

echo ""
echo -e "${BLUE}--- Live blue-green staging (productcatalogservice) ---${NC}"
kubectl patch rollout productcatalogservice -n online-boutique --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"verify-run\":\"$(date +%s)\"}}}}}" &>/dev/null

PAUSED=""
for i in $(seq 1 24); do
  PHASE=$(kubectl get rollout productcatalogservice -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$PHASE" == "Paused" ]] && { PAUSED="yes"; break; }
  sleep 5
done
if [[ "$PAUSED" == "yes" ]]; then
  check_pass "productcatalogservice correctly PAUSED for manual promotion instead of auto-cutting-over"
  echo "         Promote it yourself: kubectl argo rollouts promote productcatalogservice -n online-boutique"
else
  check_warn "Rollout phase is '${PHASE:-<none>}', not Paused within 2 minutes — check: kubectl describe rollout productcatalogservice -n online-boutique"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 12 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 12 complete!${NC}"
  echo -e "    Next: cat modules/13-cluster-operations/README.md"
  echo ""
  exit 0
fi
