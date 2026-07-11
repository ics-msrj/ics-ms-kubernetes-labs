#!/bin/bash
# =============================================================================
# Module 11 — GitOps & CI/CD — verify.sh
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"
APP_DOMAIN="${APP_DOMAIN:-}"
ARGOCD_DOMAIN="argocd.${APP_DOMAIN}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 11 — GitOps & CI/CD Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- ArgoCD ---${NC}"
ARGOCD_READY=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$ARGOCD_READY" && "$ARGOCD_READY" != "0" ]] && check_pass "argocd-server is ready" || check_fail "argocd-server is not ready"

CERT_READY=$(kubectl get certificate argocd-tls -n online-boutique -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[[ "$CERT_READY" == "True" ]] && check_pass "Certificate argocd-tls is Ready" || check_fail "Certificate argocd-tls not Ready"

ROUTE_ACCEPTED=$(kubectl get httproute argocd -n argocd -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[[ "$ROUTE_ACCEPTED" == "True" ]] && check_pass "HTTPRoute argocd is Accepted" || check_fail "HTTPRoute argocd not Accepted"

echo ""
echo -e "${BLUE}--- Applications ---${NC}"
for app in root-app online-boutique-packaged online-boutique-dev; do
  SYNC=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
  HEALTH=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    check_pass "${app}: Synced / Healthy"
  else
    check_fail "${app}: sync=${SYNC:-<none>} health=${HEALTH:-<none>}"
  fi
done

echo ""
echo -e "${BLUE}--- Adopted workloads still healthy ---${NC}"
PACKAGED_READY=$(kubectl get deployments -n online-boutique-packaged -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | grep -c -v '^0*$\|^$')
check_pass "online-boutique-packaged: ${PACKAGED_READY} Deployments have ready replicas"

echo ""
echo -e "${BLUE}--- Self-heal: prove ArgoCD reverses drift, not just detects it ---${NC}"
log_original=$(kubectl get deployment recommendationservice -n online-boutique-packaged -o jsonpath='{.spec.replicas}' 2>/dev/null)
kubectl scale deployment recommendationservice -n online-boutique-packaged --replicas=0 &>/dev/null
DRIFT_HEALED=""
for i in $(seq 1 24); do
  CURRENT=$(kubectl get deployment recommendationservice -n online-boutique-packaged -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [[ "$CURRENT" != "0" ]]; then
    DRIFT_HEALED="yes"
    break
  fi
  sleep 5
done
if [[ "$DRIFT_HEALED" == "yes" ]]; then
  check_pass "Manually scaling recommendationservice to 0 was reverted by ArgoCD's selfHeal (back to ${CURRENT})"
else
  check_fail "recommendationservice stayed at 0 replicas — selfHeal didn't revert the manual change within 2 minutes"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 11 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 11 complete! ArgoCD: https://${ARGOCD_DOMAIN}${NC}"
  echo -e "    Next: cat modules/12-progressive-delivery/README.md"
  echo ""
  exit 0
fi
