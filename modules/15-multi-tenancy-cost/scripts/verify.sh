#!/bin/bash
# =============================================================================
# Module 15 — Multi-Tenancy & Cost — verify.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 15 — Multi-Tenancy & Cost Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- ResourceQuota / LimitRange ---${NC}"
if kubectl get resourcequota online-boutique-quota -n online-boutique &>/dev/null; then
  USED_CPU=$(kubectl get resourcequota online-boutique-quota -n online-boutique -o jsonpath='{.status.used.requests\.cpu}' 2>/dev/null)
  HARD_CPU=$(kubectl get resourcequota online-boutique-quota -n online-boutique -o jsonpath='{.status.hard.requests\.cpu}' 2>/dev/null)
  check_pass "ResourceQuota online-boutique-quota exists (CPU requests used: ${USED_CPU:-?} / ${HARD_CPU:-?})"
else
  check_fail "ResourceQuota online-boutique-quota not found"
fi
kubectl get limitrange online-boutique-limits -n online-boutique &>/dev/null \
  && check_pass "LimitRange online-boutique-limits exists" || check_fail "LimitRange not found"

echo ""
echo -e "${BLUE}--- Quota is actually enforced ---${NC}"
kubectl delete pod quota-violation-test -n online-boutique --ignore-not-found=true --wait=false &>/dev/null
if kubectl run quota-violation-test -n online-boutique --image=busybox:1.36 --restart=Never \
    --overrides='{"spec":{"containers":[{"name":"quota-violation-test","image":"busybox:1.36","resources":{"requests":{"cpu":"10"}}}]}}' \
    &>/dev/null; then
  check_fail "A pod requesting 10 CPU (far beyond the quota) was ALLOWED — quota is not enforcing"
  kubectl delete pod quota-violation-test -n online-boutique --ignore-not-found=true --wait=false &>/dev/null
else
  check_pass "A pod requesting 10 CPU was correctly REJECTED by the ResourceQuota"
fi

echo ""
echo -e "${BLUE}--- OpenCost ---${NC}"
OC_READY=$(kubectl get deployment opencost -n opencost -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$OC_READY" && "$OC_READY" != "0" ]] && check_pass "OpenCost is ready" || check_fail "OpenCost is not ready"

HEALTH=$(kubectl run opencost-health-$$ --image=curlimages/curl:8.10.1 --restart=Never --rm -q -i --timeout=30s \
  --overrides="{\"spec\":{\"containers\":[{\"name\":\"opencost-health-$$\",\"image\":\"curlimages/curl:8.10.1\",\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"50m\",\"memory\":\"32Mi\"}}}]}}" -- \
  curl -s --max-time 10 -o /dev/null -w "%{http_code}" "http://opencost.opencost.svc:9003/healthz" \
  </dev/null 2>/dev/null)
if [[ "$HEALTH" == "200" ]]; then
  check_pass "OpenCost API is healthy"
else
  check_warn "OpenCost /healthz returned '${HEALTH:-<none>}' — it may still be building its initial cost model, give it a few minutes"
fi

ALLOCATION=$(kubectl run opencost-alloc-$$ --image=curlimages/curl:8.10.1 --restart=Never --rm -q -i --timeout=30s \
  --overrides="{\"spec\":{\"containers\":[{\"name\":\"opencost-alloc-$$\",\"image\":\"curlimages/curl:8.10.1\",\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"50m\",\"memory\":\"32Mi\"}}}]}}" -- \
  curl -s --max-time 10 "http://opencost.opencost.svc:9003/allocation/compute?window=10m" \
  </dev/null 2>/dev/null)
if echo "$ALLOCATION" | grep -q '"code":200'; then
  check_pass "OpenCost is successfully computing cost allocation from Module 08's Prometheus"
else
  check_warn "Could not confirm a successful allocation response yet — OpenCost needs a few minutes of real Prometheus data before this works"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 15 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 15 complete!${NC}"
  echo -e "    Next: cat modules/16-supply-chain-security/README.md"
  echo ""
  exit 0
fi
