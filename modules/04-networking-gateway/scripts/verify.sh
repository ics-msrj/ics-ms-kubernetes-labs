#!/bin/bash
# =============================================================================
# Module 04 — Networking & Gateway API — verify.sh
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"
APP_DOMAIN="${APP_DOMAIN:-}"
TLS_ISSUER="${TLS_ISSUER:-letsencrypt-staging}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 04 — Networking & Gateway API Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Gateway API ---${NC}"
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  check_pass "Gateway API CRDs installed"
else
  check_fail "Gateway API CRDs not found"
fi

GWCLASS_ACCEPTED=$(kubectl get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
if [[ "$GWCLASS_ACCEPTED" == "True" ]]; then
  check_pass "GatewayClass 'cilium' is Accepted"
else
  check_fail "GatewayClass 'cilium' not Accepted (got '${GWCLASS_ACCEPTED:-<none>}')"
fi

GW_PROGRAMMED=$(kubectl get gateway frontend-gateway -n online-boutique -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
if [[ "$GW_PROGRAMMED" == "True" ]]; then
  check_pass "Gateway frontend-gateway is Programmed"
else
  check_fail "Gateway frontend-gateway not Programmed (got '${GW_PROGRAMMED:-<none>}')"
fi

ROUTE_ACCEPTED=$(kubectl get httproute frontend -n online-boutique -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
if [[ "$ROUTE_ACCEPTED" == "True" ]]; then
  check_pass "HTTPRoute frontend is Accepted"
else
  check_fail "HTTPRoute frontend not Accepted (got '${ROUTE_ACCEPTED:-<none>}')"
fi

echo ""
echo -e "${BLUE}--- cert-manager ---${NC}"
for dep in cert-manager cert-manager-webhook cert-manager-cainjector; do
  READY=$(kubectl get deployment "$dep" -n cert-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [[ -n "$READY" && "$READY" != "0" ]]; then
    check_pass "$dep is ready"
  else
    check_fail "$dep is not ready"
  fi
done

ISSUER_READY=$(kubectl get clusterissuer "${TLS_ISSUER}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [[ "$ISSUER_READY" == "True" ]]; then
  check_pass "ClusterIssuer ${TLS_ISSUER} is Ready"
else
  check_fail "ClusterIssuer ${TLS_ISSUER} not Ready (got '${ISSUER_READY:-<none>}')"
fi

CERT_READY=$(kubectl get certificate frontend-tls -n online-boutique -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [[ "$CERT_READY" == "True" ]]; then
  check_pass "Certificate frontend-tls is Ready"
else
  check_fail "Certificate frontend-tls not Ready (got '${CERT_READY:-<none>}') — check: kubectl describe certificate frontend-tls -n online-boutique"
fi

echo ""
echo -e "${BLUE}--- NetworkPolicy: redis-cart locked to cartservice ---${NC}"
if kubectl get networkpolicy redis-cart-allow-cartservice-only -n online-boutique &>/dev/null; then
  check_pass "NetworkPolicy redis-cart-allow-cartservice-only exists"
else
  check_fail "NetworkPolicy redis-cart-allow-cartservice-only not found"
fi

probe_redis() {
  local name="$1" labels="$2"
  kubectl delete pod "$name" -n online-boutique --ignore-not-found=true --wait=true &>/dev/null
  kubectl run "$name" -n online-boutique --image=busybox:1.36 --restart=Never \
    --labels="$labels" --command -- sh -c "nc -z -w3 redis-cart 6379" &>/dev/null
  kubectl wait pod "$name" -n online-boutique --for=jsonpath='{.status.phase}'=Succeeded --timeout=25s &>/dev/null
  local result=$?
  kubectl delete pod "$name" -n online-boutique --ignore-not-found=true --wait=false &>/dev/null
  return $result
}

if probe_redis netpol-test-denied "app=netpol-test-denied"; then
  check_fail "A non-cartservice pod reached redis-cart:6379 — policy is not enforcing"
else
  check_pass "A non-cartservice pod is correctly blocked from redis-cart:6379"
fi

if probe_redis netpol-test-allowed "app=cartservice"; then
  check_pass "A pod labeled app=cartservice can reach redis-cart:6379"
else
  check_fail "A pod labeled app=cartservice could NOT reach redis-cart:6379 — policy is too strict, check port/label match"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 04 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 04 complete! Browse: https://${APP_DOMAIN}${NC}"
  echo -e "    Next: cat modules/05-storage/README.md"
  echo ""
  exit 0
fi
