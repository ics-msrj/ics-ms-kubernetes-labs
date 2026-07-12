#!/bin/bash
# =============================================================================
# Module 01 — Cluster Setup Verification
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0

check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 01 — Cluster Setup Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- kubectl connectivity ---${NC}"
if kubectl cluster-info &>/dev/null; then
  check_pass "kubectl can reach the cluster"
else
  check_fail "kubectl cannot reach the cluster — check KUBECONFIG"
  echo ""
  echo "  Hint: export KUBECONFIG=\$(pwd)/modules/01-cluster-setup/kubeconfig.yaml"
  echo "  Or run: bash modules/01-cluster-setup/scripts/export-kubeconfig.sh"
  echo ""
  echo "================================================================"
  exit 1
fi

echo ""
echo -e "${BLUE}--- Node status ---${NC}"

NODES_TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
NODES_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
CONTROL_PLANE_NODES=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | awk '{print $1}')
CONTROL_PLANE_COUNT=$(echo "${CONTROL_PLANE_NODES}" | grep -c . || true)
WORKER_NODES=$(kubectl get nodes --no-headers 2>/dev/null | awk '$3 !~ /control-plane/ {print $1}')
WORKER_COUNT=$(echo "${WORKER_NODES}" | grep -c . || true)

if (( CONTROL_PLANE_COUNT >= 1 )); then
  check_pass "Found ${CONTROL_PLANE_COUNT} control-plane node(s): $(echo "${CONTROL_PLANE_NODES}" | tr '\n' ' ')"
else
  check_fail "No node with role control-plane found"
fi

if (( WORKER_COUNT >= 1 )); then
  check_pass "Found ${WORKER_COUNT} worker node(s): $(echo "${WORKER_NODES}" | tr '\n' ' ')"
else
  check_fail "No worker nodes found — Online Boutique needs at least one worker so workloads don't compete with control-plane components"
fi

if (( NODES_READY == NODES_TOTAL )) && (( NODES_TOTAL > 0 )); then
  check_pass "All ${NODES_TOTAL} nodes are Ready"
else
  check_fail "${NODES_READY}/${NODES_TOTAL} nodes are Ready"
  kubectl get nodes 2>/dev/null || true
fi

echo ""
echo -e "${BLUE}--- Control plane components ---${NC}"

SYSTEM_PODS=("kube-apiserver" "kube-scheduler" "kube-controller-manager" "etcd")
for pod in "${SYSTEM_PODS[@]}"; do
  if kubectl get pods -n kube-system 2>/dev/null | grep -q "${pod}.*Running"; then
    check_pass "kube-system: ${pod} is Running"
  else
    check_fail "kube-system: ${pod} is NOT Running"
  fi
done

echo ""
echo -e "${BLUE}--- CoreDNS ---${NC}"

COREDNS_RUNNING=$(kubectl get pods -n kube-system -l k8s-app=kube-dns \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if (( COREDNS_RUNNING >= 2 )); then
  check_pass "CoreDNS: ${COREDNS_RUNNING} pods Running"
else
  check_warn "CoreDNS: only ${COREDNS_RUNNING} pods Running (expected 2)"
fi

echo ""
echo -e "${BLUE}--- Cilium CNI ---${NC}"

if kubectl get daemonset cilium -n kube-system &>/dev/null; then
  check_pass "Cilium DaemonSet exists in kube-system"

  CILIUM_RUNNING=$(kubectl get pods -n kube-system -l k8s-app=cilium \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if (( CILIUM_RUNNING == NODES_TOTAL )) && (( NODES_TOTAL > 0 )); then
    check_pass "Cilium: ${CILIUM_RUNNING}/${NODES_TOTAL} pods Running (one per node)"
  else
    check_warn "Cilium: ${CILIUM_RUNNING}/${NODES_TOTAL} pods Running — may still be starting"
  fi

  CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${CILIUM_POD}" ]]; then
    if kubectl exec -n kube-system "${CILIUM_POD}" -c cilium-agent -- cilium status --brief 2>/dev/null | grep -qi "OK"; then
      check_pass "cilium status reports OK (checked via ${CILIUM_POD})"
    else
      check_warn "Could not confirm 'cilium status OK' — check manually: kubectl exec -n kube-system ${CILIUM_POD} -c cilium-agent -- cilium status"
    fi
  fi
else
  check_fail "Cilium DaemonSet not found in kube-system — CNI not installed"
fi

echo ""
echo -e "${BLUE}--- Pod-to-pod networking / DNS ---${NC}"

if kubectl run nettest-1 --image=busybox:1.36.1 \
  --restart=Never --rm -q -i \
  --overrides='{"spec":{"containers":[{"name":"nettest-1","image":"busybox:1.36.1","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}' \
  --command -- wget -qO- --timeout=10 http://kubernetes.default.svc.cluster.local/ \
  </dev/null &>/dev/null; then
  check_pass "DNS resolution (kubernetes.default.svc.cluster.local) works"
else
  check_warn "Could not verify DNS from a test pod — retry manually if the pod failed to schedule"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 01 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 01 complete! Proceed to Module 02.${NC}"
  echo -e "    Next: cat modules/02-core-workloads/README.md"
  echo ""
  exit 0
fi
