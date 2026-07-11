#!/bin/bash
# =============================================================================
# Module 07 — Scalability & HA — verify.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 07 — Scalability & HA Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- metrics-server ---${NC}"
if kubectl top nodes &>/dev/null; then
  check_pass "kubectl top nodes returns real data"
else
  check_fail "kubectl top nodes failed — metrics-server not serving metrics yet"
fi

echo ""
echo -e "${BLUE}--- HPA: frontend ---${NC}"
if kubectl get hpa frontend -n online-boutique &>/dev/null; then
  check_pass "HPA frontend exists"
  CUR_CPU=$(kubectl get hpa frontend -n online-boutique -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
  if [[ -n "$CUR_CPU" ]]; then
    check_pass "HPA is reading live CPU metrics (currently ${CUR_CPU}%)"
  else
    check_warn "HPA hasn't reported a current metric yet — give it another minute (kubectl describe hpa frontend -n online-boutique)"
  fi
  FRONTEND_REPLICAS=$(kubectl get deployment frontend -n online-boutique -o jsonpath='{.status.replicas}' 2>/dev/null)
  if [[ "${FRONTEND_REPLICAS:-0}" -ge 2 ]]; then
    check_pass "frontend has ${FRONTEND_REPLICAS} replicas (HPA's minReplicas: 2 is satisfied)"
  else
    check_fail "frontend has ${FRONTEND_REPLICAS:-0} replicas, expected >= 2"
  fi
else
  check_fail "HPA frontend not found"
fi

echo ""
echo -e "${BLUE}--- VPA: productcatalogservice (recommend-only) ---${NC}"
if kubectl get vpa productcatalogservice -n online-boutique &>/dev/null; then
  check_pass "VPA productcatalogservice exists"
  MODE=$(kubectl get vpa productcatalogservice -n online-boutique -o jsonpath='{.spec.updatePolicy.updateMode}')
  [[ "$MODE" == "Off" ]] && check_pass "VPA is in recommend-only mode (Off) — won't fight HPA" || check_fail "VPA updateMode is '${MODE}', expected 'Off'"
  REC=$(kubectl get vpa productcatalogservice -n online-boutique -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}' 2>/dev/null)
  if [[ -n "$REC" ]]; then
    check_pass "VPA has computed a recommendation (target CPU: ${REC})"
  else
    check_warn "VPA hasn't computed a recommendation yet — it needs a few minutes of metrics history, this is expected right after setup"
  fi
else
  check_fail "VPA productcatalogservice not found"
fi

echo ""
echo -e "${BLUE}--- KEDA: loadgenerator cron scaler ---${NC}"
KEDA_READY=$(kubectl get deployment keda-operator -n keda -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$KEDA_READY" && "$KEDA_READY" != "0" ]] && check_pass "keda-operator is ready" || check_fail "keda-operator is not ready"

if kubectl get scaledobject loadgenerator-cron -n online-boutique &>/dev/null; then
  check_pass "ScaledObject loadgenerator-cron exists"
  SO_READY=$(kubectl get scaledobject loadgenerator-cron -n online-boutique -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "$SO_READY" == "True" ]] && check_pass "ScaledObject is Ready" || check_fail "ScaledObject Ready condition is '${SO_READY:-<none>}'"
  LG_REPLICAS=$(kubectl get deployment loadgenerator -n online-boutique -o jsonpath='{.status.replicas}' 2>/dev/null)
  echo "         (loadgenerator currently at ${LG_REPLICAS:-0} replicas — correct value depends on the time of day; see the manifest's cron window)"
else
  check_fail "ScaledObject loadgenerator-cron not found"
fi

echo ""
echo -e "${BLUE}--- PodDisruptionBudgets ---${NC}"
for pdb in frontend cartservice; do
  HEALTHY=$(kubectl get pdb "$pdb" -n online-boutique -o jsonpath='{.status.currentHealthy}' 2>/dev/null)
  ALLOWED=$(kubectl get pdb "$pdb" -n online-boutique -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)
  if [[ -n "$HEALTHY" && "$HEALTHY" -ge 1 ]]; then
    check_pass "PDB ${pdb}: ${HEALTHY} healthy pod(s), ${ALLOWED:-0} voluntary disruption(s) currently allowed"
  else
    check_fail "PDB ${pdb}: currentHealthy='${HEALTHY:-<none>}'"
  fi
done

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 07 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 07 complete!${NC}"
  echo -e "    Next: cat modules/08-observability/README.md"
  echo ""
  exit 0
fi
