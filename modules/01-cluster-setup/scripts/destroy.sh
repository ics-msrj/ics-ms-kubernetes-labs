#!/bin/bash
# =============================================================================
# Module 01 — Cluster Setup — destroy.sh
#
# Resets kubeadm on every reachable node (control-plane + workers) via SSH,
# then removes the local kubeconfig and SSH tunnel.
#
# This does NOT stop or delete the VMs themselves — only what kubeadm
# installed on them. If you provisioned VMs with the optional Terraform in
# terraform/aws/, run `terraform destroy` there separately to remove the VMs.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MODULE_DIR="$(dirname "${SCRIPT_DIR}")"

# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"

SSH_USER="${SSH_USER:-ubuntu}"
CONTROL_IP="${CONTROL_PLANE_PUBLIC_IP:-}"
CONTROL_PRIVATE_IP="${CONTROL_PLANE_PRIVATE_IP:-}"
WORKER_IPS="${WORKER_PUBLIC_IPS:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "================================================================"
echo "  Module 01 — Cluster Setup — Cleanup"
echo "================================================================"
echo ""
log_warn "This runs 'kubeadm reset' on every reachable node over SSH."
log_warn "Your VMs will keep running — stop/delete them separately (Terraform or manually)."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted."
  exit 0
fi

reset_node() {
  local ip="$1" label="$2"
  if [[ -z "$ip" ]]; then
    return
  fi
  log_info "Resetting ${label} (${ip})..."
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${ip}" \
      "sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d /etc/kubernetes ~/.kube" 2>/dev/null; then
    log_ok "${label} reset"
  else
    log_warn "${label} (${ip}) unreachable or reset failed — reset it manually if it still exists"
  fi
}

if [[ -n "$WORKER_IPS" ]]; then
  for ip in $WORKER_IPS; do
    reset_node "$ip" "worker"
  done
else
  log_warn "WORKER_PUBLIC_IPS not set in lab.env — skipping worker reset"
fi

reset_node "$CONTROL_IP" "control-plane"

# Kill the SSH tunnel if running
if [[ -n "$CONTROL_PRIVATE_IP" ]]; then
  pkill -f "ssh.*6443:${CONTROL_PRIVATE_IP}:6443" 2>/dev/null && log_info "Killed SSH tunnel" || true
fi

# Remove local kubeconfig
KUBECONFIG_PATH="${MODULE_DIR}/kubeconfig.yaml"
if [ -f "$KUBECONFIG_PATH" ]; then
  rm -f "$KUBECONFIG_PATH"
  log_ok "Removed $(basename "$KUBECONFIG_PATH")"
fi

if [[ "${KUBECONFIG:-}" == *"01-cluster-setup"* ]]; then
  unset KUBECONFIG
  log_info "Unset KUBECONFIG in this shell"
fi

echo ""
echo "================================================================"
echo "  Module 01 cleanup complete."
echo "  Re-run Module 01 setup whenever you're ready to rebuild the cluster."
echo "================================================================"
echo ""
