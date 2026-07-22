#!/bin/bash
# =============================================================================
# Module 10 — Package Management — verify.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
GENERATED_DIR="${MODULE_DIR}/generated"
REDIS_STORAGE_SIZE="${REDIS_STORAGE_SIZE:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 10 — Package Management Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Helm chart (online-boutique-packaged) ---${NC}"
DEPLOYMENTS=(frontend cartservice checkoutservice currencyservice emailservice paymentservice \
             productcatalogservice recommendationservice shippingservice adservice loadgenerator)
READY_COUNT=0
for dep in "${DEPLOYMENTS[@]}"; do
  AVAILABLE=$(kubectl get deployment "$dep" -n online-boutique-packaged -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  [[ -n "$AVAILABLE" && "$AVAILABLE" != "0" ]] && READY_COUNT=$((READY_COUNT+1))
done
if [[ "$READY_COUNT" -eq 11 ]]; then
  check_pass "All 11 Deployments from the chart are available (11/11)"
else
  check_fail "${READY_COUNT}/11 Deployments available — check: kubectl get pods -n online-boutique-packaged"
fi

STS_READY=$(kubectl get statefulset redis-cart -n online-boutique-packaged -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ "$STS_READY" == "1" ]] && check_pass "redis-cart StatefulSet ready" || check_fail "redis-cart StatefulSet not ready"

echo ""
echo -e "${BLUE}--- Kustomize overlays rendered ---${NC}"
for env in dev staging prod; do
  if [[ -s "${GENERATED_DIR}/${env}.yaml" ]]; then
    check_pass "${env}.yaml rendered ($(grep -c '^kind:' "${GENERATED_DIR}/${env}.yaml") objects)"
  else
    check_fail "${env}.yaml missing or empty — run setup.sh"
  fi
done

echo ""
echo -e "${BLUE}--- Overlay Redis storage values ---${NC}"
DEV_STORAGE=$(grep -A1 "storage:" "${GENERATED_DIR}/dev.yaml" 2>/dev/null | grep -m1 "storage:" | awk '{print $2}')
PROD_STORAGE=$(grep -A1 "storage:" "${GENERATED_DIR}/prod.yaml" 2>/dev/null | grep -m1 "storage:" | awk '{print $2}')
if [[ -n "${REDIS_STORAGE_SIZE}" ]]; then
  EXPECTED_DEV_STORAGE="${REDIS_STORAGE_SIZE}"
  EXPECTED_PROD_STORAGE="${REDIS_STORAGE_SIZE}"
else
  EXPECTED_DEV_STORAGE="500Mi"
  EXPECTED_PROD_STORAGE="5Gi"
fi
if [[ "$DEV_STORAGE" == "${EXPECTED_DEV_STORAGE}" ]]; then
  check_pass "dev.yaml: redis-cart storage patched to ${EXPECTED_DEV_STORAGE}"
else
  check_fail "dev.yaml: redis-cart storage is '${DEV_STORAGE:-<none>}', expected ${EXPECTED_DEV_STORAGE}"
fi
if [[ "$PROD_STORAGE" == "${EXPECTED_PROD_STORAGE}" ]]; then
  check_pass "prod.yaml: redis-cart storage patched to ${EXPECTED_PROD_STORAGE}"
else
  check_fail "prod.yaml: redis-cart storage is '${PROD_STORAGE:-<none>}', expected ${EXPECTED_PROD_STORAGE}"
fi

echo ""
echo -e "${BLUE}--- dev overlay applied live (online-boutique-dev) ---${NC}"
DEV_PODS_NOT_RUNNING=$(kubectl get pods -n online-boutique-dev --no-headers 2>/dev/null | grep -v -E "Running|Completed" | wc -l)
DEV_PODS_TOTAL=$(kubectl get pods -n online-boutique-dev --no-headers 2>/dev/null | wc -l)
if [[ "$DEV_PODS_TOTAL" -gt 0 && "$DEV_PODS_NOT_RUNNING" -eq 0 ]]; then
  check_pass "All ${DEV_PODS_TOTAL} pods in online-boutique-dev are Running/Completed"
else
  check_fail "${DEV_PODS_NOT_RUNNING}/${DEV_PODS_TOTAL} pods in online-boutique-dev are not Running — check: kubectl get pods -n online-boutique-dev"
fi

DEV_CPU_LIMIT=$(kubectl get deployment frontend -n online-boutique-dev -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)
[[ "$DEV_CPU_LIMIT" == "100m" ]] && check_pass "frontend in online-boutique-dev has the patched 100m CPU limit" \
  || check_fail "frontend CPU limit is '${DEV_CPU_LIMIT:-<none>}', expected 100m"

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 10 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 10 complete!${NC}"
  echo -e "    Next: cat modules/11-gitops-cicd/README.md"
  echo ""
  exit 0
fi
