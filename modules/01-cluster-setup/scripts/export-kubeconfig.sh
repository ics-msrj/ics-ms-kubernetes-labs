#!/bin/bash
# =============================================================================
# Module 01 — Export kubeconfig to your workstation
#
# Run from your WORKSTATION (not a VM):
#   bash modules/01-cluster-setup/scripts/export-kubeconfig.sh
#
# Reads CONTROL_PLANE_PUBLIC_IP, CONTROL_PLANE_PRIVATE_IP, SSH_USER from
# lab.env (or the environment — env vars win). What this does:
#   1. SCP kubeconfig from the control-plane VM
#   2. Patch it: point at https://127.0.0.1:6443 (the SSH tunnel)
#   3. Start an SSH tunnel: localhost:6443 -> control-plane private IP:6443
#   4. Test kubectl connectivity
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"

CONTROL_IP="${CONTROL_PLANE_PUBLIC_IP:-}"
CONTROL_PRIVATE_IP="${CONTROL_PLANE_PRIVATE_IP:-}"
SSH_USER="${SSH_USER:-ubuntu}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/modules/01-cluster-setup/kubeconfig.yaml}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "============================================================"
echo "  K8s Learning Lab — Export kubeconfig"
echo "  Control plane: ${CONTROL_IP:-<unset>} (private: ${CONTROL_PRIVATE_IP:-<unset>})"
echo "============================================================"
echo ""

if [[ -z "${CONTROL_IP}" || -z "${CONTROL_PRIVATE_IP}" ]]; then
  log_warn "CONTROL_PLANE_PUBLIC_IP / CONTROL_PLANE_PRIVATE_IP not set."
  echo "Set them in lab.env, or export directly and rerun:"
  echo "  export CONTROL_PLANE_PUBLIC_IP=<control-plane-public-ip>"
  echo "  export CONTROL_PLANE_PRIVATE_IP=<control-plane-private-ip>"
  echo "Optional: export SSH_USER=ubuntu"
  exit 1
fi

log_info "Copying kubeconfig from ${SSH_USER}@${CONTROL_IP}..."
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
scp -o StrictHostKeyChecking=accept-new "${SSH_USER}@${CONTROL_IP}:~/.kube/config" "${KUBECONFIG_PATH}"
log_ok "Saved to ${KUBECONFIG_PATH}"

log_info "Patching kubeconfig for SSH tunnel access..."
kubectl config set-cluster kubernetes \
  --server="https://127.0.0.1:6443" \
  --insecure-skip-tls-verify=true \
  --kubeconfig="${KUBECONFIG_PATH}" >/dev/null
log_ok "kubeconfig patched"

log_info "Checking for an existing SSH tunnel on port 6443..."
pkill -f "ssh.*6443:${CONTROL_PRIVATE_IP}:6443" 2>/dev/null && log_info "Killed existing tunnel" || true
sleep 1

log_info "Starting SSH tunnel: localhost:6443 -> ${CONTROL_PRIVATE_IP}:6443 via ${CONTROL_IP}..."
ssh -f -N -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -L "6443:${CONTROL_PRIVATE_IP}:6443" \
  "${SSH_USER}@${CONTROL_IP}"
sleep 2
log_ok "SSH tunnel started"

log_info "Testing kubectl connectivity..."
export KUBECONFIG="${KUBECONFIG_PATH}"

if kubectl get nodes 2>/dev/null; then
  log_ok "kubectl connected successfully"
else
  log_warn "kubectl test failed — the tunnel may need a moment. Try:"
  echo "  export KUBECONFIG=${KUBECONFIG_PATH}"
  echo "  kubectl get nodes"
fi

echo ""
echo "============================================================"
echo "  Done. To use kubectl in any terminal:"
echo ""
echo "  export KUBECONFIG=${KUBECONFIG_PATH}"
echo ""
echo "  To restart the tunnel if disconnected:"
echo "  ssh -f -N -L 6443:${CONTROL_PRIVATE_IP}:6443 ${SSH_USER}@${CONTROL_IP}"
echo "============================================================"
echo ""
