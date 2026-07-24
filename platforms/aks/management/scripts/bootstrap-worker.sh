#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command scp
require_command ssh
require_ssh worker

JOIN_COMMAND="${MANAGEMENT_DIR}/generated/join-command.sh"
[[ -f "${JOIN_COMMAND}" ]] \
  || die "No ${JOIN_COMMAND} — run bootstrap-control-plane first (it fetches the join command from the control plane)."

echo ""
echo "================================================================"
echo "  Rancher Management Cluster - kubeadm worker bootstrap"
echo "================================================================"
echo ""

log_info "Copying kubeadm worker setup script and join command to the VM..."
scp -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" \
  "${SCRIPT_DIR}/kubeadm/setup-worker.sh" \
  "${JOIN_COMMAND}" \
  "${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_WORKER_PUBLIC_IP}:/tmp/"

log_info "Running kubeadm worker setup on the VM..."
ssh -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" "${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_WORKER_PUBLIC_IP}" \
  "sudo NODE_NAME=${AKS_MANAGEMENT_WORKER_NODE_NAME} NODE_IP=${AKS_MANAGEMENT_WORKER_PRIVATE_IP} bash /tmp/setup-worker.sh"

log_ok "Worker bootstrapped."
echo ""
echo "Next: bash platforms/aks/management/scripts/platform-track.sh export-kubeconfig"
