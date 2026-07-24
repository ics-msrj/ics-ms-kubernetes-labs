#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command curl
require_config
require_cluster
require_rancher_config

PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS + 1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN + 1)); }

echo ""
echo "================================================================"
echo "  ACK Rancher Management Cluster - Verification"
echo "================================================================"

echo ""
echo -e "${BLUE}--- Management server ---${NC}"
READY_REPLICAS="$(kubectl get deployment rancher -n cattle-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[[ "${READY_REPLICAS}" == "${ACK_MANAGEMENT_RANCHER_REPLICAS}" ]] \
  && check_pass "Rancher has ${READY_REPLICAS}/${ACK_MANAGEMENT_RANCHER_REPLICAS} ready replica(s)" \
  || check_fail "Rancher has ${READY_REPLICAS:-0}/${ACK_MANAGEMENT_RANCHER_REPLICAS} ready replica(s)"

kubectl get service rancher -n cattle-system >/dev/null 2>&1 \
  && check_pass "Rancher ClusterIP Service exists" \
  || check_fail "Rancher ClusterIP Service is missing"

for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
  READY="$(kubectl get deployment "${deployment}" -n cert-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  [[ -n "${READY}" && "${READY}" != "0" ]] \
    && check_pass "${deployment} is ready" \
    || check_fail "${deployment} is not ready"
done

CLOUDFLARED_READY="$(kubectl get deployment cloudflared -n cloudflare-tunnel -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[[ -n "${CLOUDFLARED_READY}" && "${CLOUDFLARED_READY}" != "0" ]] \
  && check_pass "Cloudflare Tunnel connector is ready" \
  || check_fail "Cloudflare Tunnel connector is not ready"

if curl --fail --silent --show-error --max-time 20 "https://${ACK_MANAGEMENT_RANCHER_HOSTNAME}/ping" | grep -qx 'pong'; then
  check_pass "Rancher is reachable through https://${ACK_MANAGEMENT_RANCHER_HOSTNAME}"
else
  check_fail "Rancher is not reachable through https://${ACK_MANAGEMENT_RANCHER_HOSTNAME}; verify the Cloudflare public hostname route"
fi

echo ""
echo -e "${BLUE}--- Downstream clusters ---${NC}"
if ! kubectl get crd clusters.management.cattle.io >/dev/null 2>&1; then
  check_fail "Rancher management Cluster CRD is missing"
elif [[ -n "${ACK_MANAGEMENT_EXPECTED_DOWNSTREAMS}" ]]; then
  IFS=',' read -r -a downstream_clusters <<<"${ACK_MANAGEMENT_EXPECTED_DOWNSTREAMS}"
  for cluster_name in "${downstream_clusters[@]}"; do
    cluster_name="$(echo "${cluster_name}" | xargs)"
    [[ -z "${cluster_name}" ]] && continue
    CONNECTED="$(kubectl get clusters.management.cattle.io "${cluster_name}" -o jsonpath='{.status.conditions[?(@.type=="Connected")].status}' 2>/dev/null)"
    [[ "${CONNECTED}" == "True" ]] \
      && check_pass "Downstream ${cluster_name} is Connected" \
      || check_fail "Downstream ${cluster_name} is not Connected"
  done
else
  DOWNSTREAM_COUNT="$(kubectl get clusters.management.cattle.io -o name 2>/dev/null | grep -vc '/local$')"
  [[ "${DOWNSTREAM_COUNT}" -ge 1 ]] \
    && check_pass "${DOWNSTREAM_COUNT} downstream cluster(s) are registered" \
    || check_fail "No downstream clusters are registered"
fi

echo ""
echo "================================================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo -e "${RED}  Rancher management platform is not complete.${NC}"
  exit 1
fi

echo -e "${GREEN}  Rancher management platform complete.${NC}"
