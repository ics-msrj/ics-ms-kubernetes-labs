#!/bin/bash
# =============================================================================
# Module 14 — Multi-Cluster Management — verify.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(cd "${MODULE_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"
APP_DOMAIN="${APP_DOMAIN:-}"
RANCHER_DOMAIN="rancher.${APP_DOMAIN}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 14 — Multi-Cluster Management Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Second cluster ---${NC}"
SECOND_KUBECONFIG="${MODULE_DIR}/kubeconfig-cluster2.yaml"
if [[ -f "$SECOND_KUBECONFIG" ]] && KUBECONFIG="$SECOND_KUBECONFIG" kubectl get nodes &>/dev/null; then
  NODE_COUNT=$(KUBECONFIG="$SECOND_KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | wc -l)
  check_pass "Second cluster reachable, ${NODE_COUNT} node(s)"
else
  check_fail "Second cluster not reachable — check the :6444 tunnel (see setup.sh output) or KUBECONFIG=${SECOND_KUBECONFIG}"
fi

echo ""
echo -e "${BLUE}--- Rancher (primary cluster) ---${NC}"
RANCHER_READY=$(kubectl get deployment rancher -n cattle-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$RANCHER_READY" && "$RANCHER_READY" != "0" ]] && check_pass "Rancher is ready" || check_fail "Rancher is not ready"

kubectl get gateway -n cattle-system &>/dev/null \
  && check_pass "Rancher's Gateway exists" \
  || check_warn "No Gateway found in cattle-system — check: kubectl get gateway -n cattle-system"

echo ""
echo -e "${BLUE}--- Second cluster imported into Rancher ---${NC}"
IMPORTED=""
for crd in clusters.management.cattle.io clusters.provisioning.cattle.io; do
  if kubectl get "$crd" &>/dev/null; then
    COUNT=$(kubectl get "$crd" --no-headers 2>/dev/null | grep -vc "^local ")
    if [[ "$COUNT" -ge 1 ]]; then
      IMPORTED="yes"
      break
    fi
  fi
done
if [[ "$IMPORTED" == "yes" ]]; then
  check_pass "At least one non-local cluster is registered in Rancher"
else
  check_warn "No imported cluster found yet — this is a manual UI step, see README Step 3 (not required for the rest of this repo)"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 14 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 14 complete! Rancher: https://${RANCHER_DOMAIN}${NC}"
  echo -e "    Next: cat modules/15-multi-tenancy-cost/README.md"
  echo ""
  exit 0
fi
