#!/bin/bash
# =============================================================================
# Module 06 — Security Policy — verify.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 06 — Security Policy Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Pod Security Admission ---${NC}"
ENFORCE=$(kubectl get namespace online-boutique -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
if [[ "$ENFORCE" == "restricted" ]]; then
  check_pass "online-boutique enforces the 'restricted' Pod Security Standard"
else
  check_fail "online-boutique enforce label is '${ENFORCE:-<none>}', expected 'restricted'"
fi

NOT_RUNNING=$(kubectl get pods -n online-boutique --no-headers 2>/dev/null | grep -v -E "Running|Completed" | wc -l)
if [[ "$NOT_RUNNING" -eq 0 ]]; then
  check_pass "All existing pods are still Running — PSA didn't retroactively break anything"
else
  check_fail "${NOT_RUNNING} pod(s) not Running after enabling PSA — check: kubectl get pods -n online-boutique"
fi

log_info_probe_cleanup() { kubectl delete pod psa-violation-test -n online-boutique --ignore-not-found=true --wait=false &>/dev/null; }
trap log_info_probe_cleanup EXIT
if kubectl run psa-violation-test -n online-boutique --image=busybox:1.36 --restart=Never \
    --overrides='{"spec":{"containers":[{"name":"psa-violation-test","image":"busybox:1.36","securityContext":{"privileged":true}}]}}' \
    &>/dev/null; then
  check_fail "A privileged pod was ALLOWED — restricted PSA is not actually enforcing"
else
  check_pass "A privileged pod was correctly REJECTED by restricted PSA"
fi

echo ""
echo -e "${BLUE}--- RBAC: viewer ---${NC}"
kubectl auth can-i get pods -n online-boutique --as=system:serviceaccount:online-boutique:viewer &>/dev/null \
  && check_pass "viewer CAN get pods" || check_fail "viewer cannot get pods (expected: can)"
kubectl auth can-i get secrets -n online-boutique --as=system:serviceaccount:online-boutique:viewer &>/dev/null \
  && check_fail "viewer CAN get secrets (expected: cannot)" || check_pass "viewer correctly CANNOT get secrets"
kubectl auth can-i delete deployments -n online-boutique --as=system:serviceaccount:online-boutique:viewer &>/dev/null \
  && check_fail "viewer CAN delete deployments (expected: cannot)" || check_pass "viewer correctly CANNOT delete deployments"

echo ""
echo -e "${BLUE}--- RBAC: ci-deployer ---${NC}"
kubectl auth can-i patch deployments -n online-boutique --as=system:serviceaccount:online-boutique:ci-deployer &>/dev/null \
  && check_pass "ci-deployer CAN patch deployments" || check_fail "ci-deployer cannot patch deployments (expected: can)"
kubectl auth can-i get secrets -n online-boutique --as=system:serviceaccount:online-boutique:ci-deployer &>/dev/null \
  && check_fail "ci-deployer CAN get secrets (expected: cannot)" || check_pass "ci-deployer correctly CANNOT get secrets"
kubectl auth can-i create pods -n online-boutique --as=system:serviceaccount:online-boutique:ci-deployer &>/dev/null \
  && check_fail "ci-deployer CAN create pods (expected: cannot)" || check_pass "ci-deployer correctly CANNOT create pods"

echo ""
echo -e "${BLUE}--- Kyverno ---${NC}"
ADM_READY=$(kubectl get deployment kyverno-admission-controller -n kyverno -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [[ -n "$ADM_READY" && "$ADM_READY" != "0" ]]; then
  check_pass "kyverno-admission-controller is ready"
else
  check_fail "kyverno-admission-controller is not ready"
fi

for policy in disallow-latest-tag require-resource-limits; do
  # Kyverno 3.x reports readiness via status.conditions[type=Ready], not the
  # older status.ready boolean — check conditions first, fall back to the
  # old field for older chart versions.
  READY=$(kubectl get clusterpolicy "$policy" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ -z "$READY" ]] && READY=$(kubectl get clusterpolicy "$policy" -o jsonpath='{.status.ready}' 2>/dev/null)
  if [[ "$READY" == "True" || "$READY" == "true" ]]; then
    check_pass "ClusterPolicy ${policy} is ready"
  else
    check_fail "ClusterPolicy ${policy} not ready (got '${READY:-<none>}')"
  fi
done

echo ""
echo -e "${BLUE}--- Kyverno enforcement (live admission test) ---${NC}"
if kubectl run kyverno-latest-test -n online-boutique --image=busybox:latest --restart=Never \
    --overrides='{"spec":{"containers":[{"name":"kyverno-latest-test","image":"busybox:latest","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"20m","memory":"32Mi"}}}]}}' \
    &>/dev/null; then
  check_fail "A pod using ':latest' was ALLOWED — disallow-latest-tag is not enforcing"
  kubectl delete pod kyverno-latest-test -n online-boutique --ignore-not-found=true --wait=false &>/dev/null
else
  check_pass "A pod using ':latest' was correctly REJECTED"
fi

if kubectl run kyverno-noresources-test -n online-boutique --image=busybox:1.36 --restart=Never \
    --command -- sleep 3600 &>/dev/null; then
  check_fail "A pod with no resource requests/limits was ALLOWED — require-resource-limits is not enforcing"
  kubectl delete pod kyverno-noresources-test -n online-boutique --ignore-not-found=true --wait=false &>/dev/null
else
  check_pass "A pod with no resource requests/limits was correctly REJECTED"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 06 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 06 complete!${NC}"
  echo -e "    Next: cat modules/07-scalability-ha/README.md"
  echo ""
  exit 0
fi
