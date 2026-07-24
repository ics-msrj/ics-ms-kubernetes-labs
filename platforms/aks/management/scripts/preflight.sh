#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

for command in ssh scp kubectl helm curl git jq az terraform; do
  require_command "${command}"
done
require_ssh cp
require_ssh worker

echo ""
echo "================================================================"
echo "  Rancher Management Cluster - Preflight"
echo "================================================================"
echo ""

log_ok "SSH reaches ${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_CP_PUBLIC_IP} (control-plane)"
log_ok "SSH reaches ${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_WORKER_PUBLIC_IP} (worker)"

if ssh -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" "${AKS_MANAGEMENT_SSH_USER}@${AKS_MANAGEMENT_CP_PUBLIC_IP}" \
  '[[ -f /etc/kubernetes/admin.conf ]]' 2>/dev/null; then
  log_warn "kubeadm cluster already initialized on the control-plane VM; bootstrap-control-plane will skip re-running kubeadm init."
fi

for target in cp worker; do
  case "${target}" in
    cp) ip="${AKS_MANAGEMENT_CP_PUBLIC_IP}" ;;
    worker) ip="${AKS_MANAGEMENT_WORKER_PUBLIC_IP}" ;;
  esac
  if ssh -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" "${AKS_MANAGEMENT_SSH_USER}@${ip}" \
    'command -v kubectl >/dev/null 2>&1 && sudo test -f /etc/kubernetes/admin.conf && sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get namespace online-boutique' \
    >/dev/null 2>&1; then
    die "online-boutique exists on the ${target} node's cluster. Refusing to use a workload cluster as the Rancher management cluster."
  fi
done

log_ok "Dedicated-management-cluster guard passed"
echo ""
echo "Next: bash platforms/aks/management/scripts/platform-track.sh bootstrap-control-plane"
