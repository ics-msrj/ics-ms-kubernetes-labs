#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command scp
require_command ssh
require_ssh cp

echo ""
echo "================================================================"
echo "  Rancher Management Cluster - kubeadm control-plane bootstrap"
echo "================================================================"
echo ""

log_info "Copying kubeadm control-plane setup script to the VM..."
scp -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" \
  "${SCRIPT_DIR}/kubeadm/setup-control-plane.sh" \
  "${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_CP_PUBLIC_IP}:/tmp/setup-control-plane.sh"

log_info "Running kubeadm control-plane setup on the VM (this takes several minutes)..."
ssh -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" "${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_CP_PUBLIC_IP}" \
  "sudo CONTROL_PLANE_IP=${AKS_MANAGEMENT_CP_PRIVATE_IP} NODE_NAME=${AKS_MANAGEMENT_CP_NODE_NAME} bash /tmp/setup-control-plane.sh"

log_info "Fetching the worker join command..."
mkdir -p "${MANAGEMENT_DIR}/generated"
scp -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" \
  "${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_CP_PUBLIC_IP}:/tmp/join-command.sh" \
  "${MANAGEMENT_DIR}/generated/join-command.sh"

log_ok "Control-plane bootstrapped."
echo ""
echo "Next: bash platforms/aks/management/scripts/platform-track.sh bootstrap-worker"
