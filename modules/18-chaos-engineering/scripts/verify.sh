#!/bin/bash
# =============================================================================
# Module 18 — Chaos Engineering & Incident Response — verify.sh
#
# Checks that Chaos Mesh itself is healthy. Does NOT run any experiment —
# pod-kill/network-chaos/stress-chaos are genuinely disruptive and are only
# ever triggered by hand, following the README's Lab steps.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }

echo ""
echo "================================================================"
echo "   Module 18 — Chaos Engineering Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Chaos Mesh control plane ---${NC}"
CTRL_READY=$(kubectl get deployment chaos-mesh-controller-manager -n chaos-mesh -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$CTRL_READY" && "$CTRL_READY" != "0" ]] && check_pass "chaos-controller-manager is ready" || check_fail "chaos-controller-manager is not ready"

DASH_READY=$(kubectl get deployment chaos-dashboard -n chaos-mesh -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$DASH_READY" && "$DASH_READY" != "0" ]] && check_pass "chaos-dashboard is ready" || check_fail "chaos-dashboard is not ready"

echo ""
echo -e "${BLUE}--- chaos-daemon (one per node) ---${NC}"
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
DAEMON_READY=$(kubectl get daemonset chaos-daemon -n chaos-mesh -o jsonpath='{.status.numberReady}' 2>/dev/null)
if [[ -n "$DAEMON_READY" && "$DAEMON_READY" == "$NODE_COUNT" ]]; then
  check_pass "chaos-daemon ready on all ${NODE_COUNT} nodes"
else
  check_fail "chaos-daemon ready on ${DAEMON_READY:-0}/${NODE_COUNT} nodes"
fi

echo ""
echo -e "${BLUE}--- CRDs ---${NC}"
for crd in podchaos networkchaos stresschaos workflows.chaos-mesh.org; do
  kubectl get crd | grep -q "$crd" && check_pass "CRD ${crd} installed" || check_fail "CRD ${crd} not found"
done

echo ""
echo -e "${BLUE}--- No experiment left running ---${NC}"
LEFTOVER=$(kubectl get podchaos,networkchaos,stresschaos,workflow -n online-boutique --no-headers 2>/dev/null | wc -l)
if [[ "$LEFTOVER" -eq 0 ]]; then
  check_pass "No chaos experiments currently applied to online-boutique"
else
  echo -e "  ${YELLOW}NOTE${NC}  ${LEFTOVER} chaos object(s) still present — expected if you're mid-drill, otherwise clean up:"
  kubectl get podchaos,networkchaos,stresschaos,workflow -n online-boutique 2>/dev/null | sed 's/^/         /'
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 18 setup NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Chaos Mesh is ready. Run the GameDay scenarios from this module's README.${NC}"
  echo -e "    Next (after the drills): cat modules/99-capstone/README.md"
  echo ""
  exit 0
fi
