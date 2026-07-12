#!/bin/bash
# =============================================================================
# Module 16 — Supply Chain Security — verify.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
GENERATED_DIR="${MODULE_DIR}/generated"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 16 — Supply Chain Security Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Trivy Operator ---${NC}"
TRIVY_READY=$(kubectl get deployment trivy-operator -n trivy-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$TRIVY_READY" && "$TRIVY_READY" != "0" ]] && check_pass "Trivy Operator is ready" || check_fail "Trivy Operator is not ready"

REPORT_COUNT=$(kubectl get vulnerabilityreports -n online-boutique --no-headers 2>/dev/null | wc -l)
if [[ "$REPORT_COUNT" -ge 1 ]]; then
  check_pass "${REPORT_COUNT} VulnerabilityReport(s) generated for online-boutique's real images"
else
  check_warn "No VulnerabilityReports yet for online-boutique — scanning can take a few minutes after install"
fi

echo ""
echo -e "${BLUE}--- SBOM ---${NC}"
if [[ -s "${GENERATED_DIR}/frontend-sbom.json" ]]; then
  COMPONENT_COUNT=$(grep -o '"type"' "${GENERATED_DIR}/frontend-sbom.json" | wc -l)
  check_pass "SBOM exists (${GENERATED_DIR}/frontend-sbom.json, ~${COMPONENT_COUNT} entries)"
else
  check_fail "No SBOM found at ${GENERATED_DIR}/frontend-sbom.json"
fi

echo ""
echo -e "${BLUE}--- Registry + signed image ---${NC}"
REGISTRY_READY=$(kubectl get deployment registry -n supply-chain-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$REGISTRY_READY" && "$REGISTRY_READY" != "0" ]] && check_pass "Self-hosted registry is ready" || check_fail "Registry is not ready"

SIGNED_POD_PHASE=$(kubectl get pod signed-image-test -n supply-chain-demo -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "$SIGNED_POD_PHASE" == "Running" ]]; then
  check_pass "The signed image was admitted and is Running"
else
  check_fail "signed-image-test is '${SIGNED_POD_PHASE:-<not found>}', expected Running"
fi

echo ""
echo -e "${BLUE}--- Unsigned image is actually rejected (not just theoretically) ---${NC}"
if command -v crane &>/dev/null; then
  pkill -f "port-forward.*supply-chain-demo.*5000" 2>/dev/null || true
  sleep 1
  kubectl port-forward -n supply-chain-demo svc/registry 5000:5000 &>/dev/null &
  PF_PID=$!
  sleep 3
  crane copy busybox:1.36 localhost:5000/unsigned-test:v1 --insecure &>/dev/null
  kill "$PF_PID" 2>/dev/null || true

  kubectl delete pod unsigned-image-test -n supply-chain-demo --ignore-not-found=true --wait=true &>/dev/null
  if kubectl run unsigned-image-test -n supply-chain-demo \
      --image=registry.supply-chain-demo.svc.cluster.local:5000/unsigned-test:v1 \
      --restart=Never \
      --overrides='{"spec":{"containers":[{"name":"unsigned-image-test","image":"registry.supply-chain-demo.svc.cluster.local:5000/unsigned-test:v1","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}' \
      &>/dev/null; then
    check_fail "An UNSIGNED image from our own registry was ALLOWED — verifyImages is not enforcing"
    kubectl delete pod unsigned-image-test -n supply-chain-demo --ignore-not-found=true --wait=false &>/dev/null
  else
    check_pass "An unsigned image from our own registry was correctly REJECTED"
  fi
else
  check_warn "crane not on PATH — skipping the live unsigned-image rejection test"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 16 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 16 complete!${NC}"
  echo -e "    Next: cat modules/17-service-mesh/README.md"
  echo ""
  exit 0
fi
