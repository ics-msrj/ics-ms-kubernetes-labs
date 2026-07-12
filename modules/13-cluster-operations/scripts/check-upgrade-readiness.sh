#!/bin/bash
# =============================================================================
# Module 13 — Cluster Operations — check-upgrade-readiness.sh
#
# Read-only. Runs `kubeadm upgrade plan` on the control-plane node — a
# command Kubernetes' own docs describe as safe: it fetches version info,
# runs preflight checks, and reports what an upgrade WOULD do, without
# applying anything (comparable to `kubeadm upgrade apply --dry-run`).
#
# This exists because "kubeadm upgrade" itself stays a manual walkthrough
# in this module's README (Step 4) — too risky to script blindly — but
# knowing WHETHER you're behind, and by how much, carries none of that
# risk. Run this any time; it changes nothing on your cluster.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"

SSH_USER="${SSH_USER:-ubuntu}"
CONTROL_IP="${CONTROL_PLANE_PUBLIC_IP:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }

if [[ -z "$CONTROL_IP" ]]; then
  echo -e "${RED}[ERROR]${NC} CONTROL_PLANE_PUBLIC_IP not set in lab.env." >&2
  exit 1
fi

echo ""
echo "================================================================"
echo "  Module 13 — kubeadm Upgrade Readiness (read-only)"
echo "================================================================"
echo ""
log_info "Connecting to control-plane (${CONTROL_IP})..."
echo ""

echo -e "${BLUE}--- Currently installed versions ---${NC}"
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${CONTROL_IP}" \
  'kubeadm version -o short; kubelet --version; kubectl version --client -o yaml 2>/dev/null | grep gitVersion'

echo ""
echo -e "${BLUE}--- kubeadm upgrade plan (fetches and reports only — no changes) ---${NC}"
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${CONTROL_IP}" \
  'sudo kubeadm upgrade plan'

echo ""
echo -e "${BLUE}--- Node versions across the cluster (from this workstation) ---${NC}"
kubectl get nodes -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion' 2>/dev/null

echo ""
echo "================================================================"
log_ok "Read-only check complete — nothing on the cluster was changed."
echo -e "${YELLOW}To actually upgrade, follow the manual walkthrough in this${NC}"
echo -e "${YELLOW}module's README (Step 4) — that step stays deliberately${NC}"
echo -e "${YELLOW}unscripted; a script that gets a live upgrade wrong mid-way${NC}"
echo -e "${YELLOW}can leave the cluster in a state that's hard to reason about.${NC}"
echo "================================================================"
echo ""
