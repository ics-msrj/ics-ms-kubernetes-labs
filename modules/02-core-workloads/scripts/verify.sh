#!/bin/bash
# =============================================================================
# Module 02 — Core Workloads — verify.sh
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
echo "   Module 02 — Core Workloads Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Namespace ---${NC}"
if kubectl get namespace online-boutique &>/dev/null; then
  check_pass "Namespace online-boutique exists"
else
  check_fail "Namespace online-boutique not found — run setup.sh"
  exit 1
fi

echo ""
echo -e "${BLUE}--- Deployments (11 Online Boutique services) ---${NC}"
DEPLOYMENTS=(frontend cartservice checkoutservice currencyservice emailservice paymentservice \
             productcatalogservice recommendationservice shippingservice adservice loadgenerator)
for dep in "${DEPLOYMENTS[@]}"; do
  AVAILABLE=$(kubectl get deployment "$dep" -n online-boutique -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  DESIRED=$(kubectl get deployment "$dep" -n online-boutique -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [[ -n "$AVAILABLE" && "$AVAILABLE" == "$DESIRED" && "$AVAILABLE" != "0" ]]; then
    check_pass "$dep: ${AVAILABLE}/${DESIRED} available"
  else
    check_fail "$dep: ${AVAILABLE:-0}/${DESIRED:-?} available"
  fi
done

echo ""
echo -e "${BLUE}--- StatefulSet: redis-cart ---${NC}"
READY=$(kubectl get statefulset redis-cart -n online-boutique -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [[ "$READY" == "1" ]]; then
  check_pass "redis-cart StatefulSet: 1/1 ready"
else
  check_fail "redis-cart StatefulSet: ${READY:-0}/1 ready"
fi

PVC_STATUS=$(kubectl get pvc redis-data-redis-cart-0 -n online-boutique -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "$PVC_STATUS" == "Bound" ]]; then
  check_pass "PVC redis-data-redis-cart-0 is Bound"
else
  check_fail "PVC redis-data-redis-cart-0 is ${PVC_STATUS:-missing} (expected Bound) — check: kubectl get pvc -n online-boutique; kubectl get pods -n local-path-storage"
fi

echo ""
echo -e "${BLUE}--- CronJob: cart-housekeeping ---${NC}"
if kubectl get cronjob cart-housekeeping -n online-boutique &>/dev/null; then
  SCHEDULE=$(kubectl get cronjob cart-housekeeping -n online-boutique -o jsonpath='{.spec.schedule}')
  check_pass "CronJob cart-housekeeping exists (schedule: ${SCHEDULE})"
else
  check_fail "CronJob cart-housekeeping not found"
fi

echo ""
echo -e "${BLUE}--- DaemonSet: node-exporter ---${NC}"
NODES_TOTAL=$(kubectl get nodes --no-headers | wc -l)
DS_READY=$(kubectl get daemonset node-exporter -n online-boutique -o jsonpath='{.status.numberReady}' 2>/dev/null)
if [[ -n "$DS_READY" && "$DS_READY" == "$NODES_TOTAL" ]]; then
  check_pass "node-exporter: ${DS_READY}/${NODES_TOTAL} nodes"
else
  check_fail "node-exporter: ${DS_READY:-0}/${NODES_TOTAL} nodes ready"
fi

echo ""
echo -e "${BLUE}--- Job: frontend smoke test ---${NC}"
kubectl delete job frontend-smoke-test -n online-boutique --ignore-not-found=true --wait=true &>/dev/null
kubectl apply -n online-boutique -f "${MODULE_DIR}/manifests/smoke-test-job.yaml" &>/dev/null
if kubectl wait --for=condition=complete job/frontend-smoke-test -n online-boutique --timeout=90s &>/dev/null; then
  check_pass "frontend-smoke-test Job completed successfully"
else
  check_fail "frontend-smoke-test Job did not complete — check: kubectl logs -n online-boutique job/frontend-smoke-test"
fi

echo ""
echo -e "${BLUE}--- All pods Running ---${NC}"
NOT_RUNNING=$(kubectl get pods -n online-boutique --no-headers 2>/dev/null | grep -v -E "Running|Completed" | wc -l)
if [[ "$NOT_RUNNING" -eq 0 ]]; then
  check_pass "All pods in online-boutique are Running or Completed"
else
  check_warn "${NOT_RUNNING} pod(s) not Running/Completed — check: kubectl get pods -n online-boutique"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 02 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 02 complete! Try it: kubectl port-forward -n online-boutique svc/frontend 8080:80${NC}"
  echo -e "    Next: cat modules/03-config-secrets/README.md"
  echo ""
  exit 0
fi
