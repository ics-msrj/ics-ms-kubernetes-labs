#!/usr/bin/env bash
# =============================================================================
# Rancher Management Cluster — export kubeconfig to your workstation.
#
# Adapted from modules/01-cluster-setup/scripts/export-kubeconfig.sh. This
# track's NSG (see ../terraform/main.tf) opens no public 6443 — the API
# server is reachable only through the SSH tunnel this script starts.
#   1. SCP kubeconfig from the VM
#   2. Patch it: point at https://127.0.0.1:6443 (the SSH tunnel)
#   3. Start an SSH tunnel: localhost:6443 -> VM private IP:6443
#   4. Test kubectl connectivity
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command scp
require_command ssh
require_command kubectl
require_config

KUBECONFIG_PATH="${MANAGEMENT_DIR}/generated/kubeconfig.yaml"

echo ""
echo "================================================================"
echo "  Rancher Management Cluster - Export kubeconfig"
echo "  Control-plane: ${AKS_MANAGEMENT_CP_PUBLIC_IP} (private: ${AKS_MANAGEMENT_CP_PRIVATE_IP})"
echo "================================================================"
echo ""

log_info "Copying kubeconfig from ${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_CP_PUBLIC_IP}..."
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
scp -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" -o StrictHostKeyChecking=accept-new \
  "${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_CP_PUBLIC_IP}:~/.kube/config" "${KUBECONFIG_PATH}"
log_ok "Saved to ${KUBECONFIG_PATH}"

log_info "Patching kubeconfig for SSH tunnel access..."
kubectl config set-cluster kubernetes \
  --server="https://127.0.0.1:6443" \
  --insecure-skip-tls-verify=true \
  --kubeconfig="${KUBECONFIG_PATH}" >/dev/null
log_ok "kubeconfig patched"

log_info "Checking for an existing SSH tunnel on port 6443..."
pkill -f "ssh.*6443:${AKS_MANAGEMENT_CP_PRIVATE_IP}:6443" 2>/dev/null && log_info "Killed existing tunnel" || true
sleep 1

log_info "Starting SSH tunnel: localhost:6443 -> ${AKS_MANAGEMENT_CP_PRIVATE_IP}:6443 via ${AKS_MANAGEMENT_CP_PUBLIC_IP}..."
ssh -f -N -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -L "6443:${AKS_MANAGEMENT_CP_PRIVATE_IP}:6443" \
  "${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_CP_PUBLIC_IP}"
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
echo "================================================================"
echo "  Done. To use kubectl in any terminal:"
echo ""
echo "  export KUBECONFIG=${KUBECONFIG_PATH}"
echo ""
echo "  To restart the tunnel if disconnected:"
echo "  ssh -f -N -i ${AKS_MANAGEMENT_SSH_KEY_PATH} -L 6443:${AKS_MANAGEMENT_CP_PRIVATE_IP}:6443 ${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_CP_PUBLIC_IP}"
echo "================================================================"
echo ""
