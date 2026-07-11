#!/bin/bash
# =============================================================================
# Module 03 — Config & Secrets — verify.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 03 — Config & Secrets Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Sealed Secrets controller ---${NC}"
CTRL_READY=$(kubectl get deployment sealed-secrets-controller -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [[ "$CTRL_READY" == "1" ]]; then
  check_pass "sealed-secrets-controller is ready"
else
  check_fail "sealed-secrets-controller not ready — run setup.sh"
fi

echo ""
echo -e "${BLUE}--- ConfigMap ---${NC}"
if kubectl get configmap online-boutique-shared-config -n online-boutique &>/dev/null; then
  check_pass "ConfigMap online-boutique-shared-config exists"
else
  check_fail "ConfigMap online-boutique-shared-config not found"
fi

echo ""
echo -e "${BLUE}--- 6 Deployments consume the ConfigMap ---${NC}"
for dep in currencyservice productcatalogservice shippingservice emailservice paymentservice recommendationservice; do
  REF=$(kubectl get deployment "$dep" -n online-boutique -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}' 2>/dev/null)
  if [[ "$REF" == "online-boutique-shared-config" ]]; then
    check_pass "$dep: envFrom -> online-boutique-shared-config"
  else
    check_fail "$dep: envFrom not set (got '${REF:-<empty>}')"
  fi
done

echo ""
echo -e "${BLUE}--- Secret (decrypted by the controller) ---${NC}"
if kubectl get secret redis-cart-credentials -n online-boutique &>/dev/null; then
  check_pass "Secret redis-cart-credentials exists"
else
  check_fail "Secret redis-cart-credentials not found — SealedSecret may have failed to decrypt, check: kubectl logs -n kube-system deployment/sealed-secrets-controller"
  echo ""
  echo "================================================================"
  exit 1
fi

echo ""
echo -e "${BLUE}--- Redis AUTH is actually enforced ---${NC}"
REDIS_PASSWORD=$(kubectl get secret redis-cart-credentials -n online-boutique -o jsonpath='{.data.password}' | base64 -d)

UNAUTH_RESULT=$(kubectl exec -n online-boutique redis-cart-0 -c redis -- redis-cli PING 2>&1)
if echo "$UNAUTH_RESULT" | grep -qi "NOAUTH"; then
  check_pass "Unauthenticated PING is correctly rejected (NOAUTH)"
else
  check_fail "Unauthenticated PING was NOT rejected — AUTH may not be enabled: got '${UNAUTH_RESULT}'"
fi

AUTH_RESULT=$(kubectl exec -n online-boutique redis-cart-0 -c redis -- redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning PING 2>&1)
if echo "$AUTH_RESULT" | grep -q "PONG"; then
  check_pass "Authenticated PING succeeds with the sealed password"
else
  check_fail "Authenticated PING failed: got '${AUTH_RESULT}'"
fi
unset REDIS_PASSWORD

echo ""
echo -e "${BLUE}--- cartservice is healthy with the new connection string ---${NC}"
RESTARTS=$(kubectl get pods -n online-boutique -l app=cartservice -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
READY=$(kubectl get pods -n online-boutique -l app=cartservice -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
if [[ "$READY" == "true" ]]; then
  check_pass "cartservice pod is Ready (restarts: ${RESTARTS:-0})"
else
  check_fail "cartservice pod is not Ready — check: kubectl logs -n online-boutique deployment/cartservice"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 03 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 03 complete!${NC}"
  echo -e "    Next: cat modules/04-networking-gateway/README.md"
  echo ""
  exit 0
fi
