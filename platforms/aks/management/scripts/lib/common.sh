#!/usr/bin/env bash

set -euo pipefail

# Deliberately not named SCRIPT_DIR: this file is sourced (not executed) by
# every other script here, each of which sets its own SCRIPT_DIR before
# sourcing this — a same-named plain assignment here would silently clobber
# the caller's value (found live: it broke bootstrap-kubeadm.sh's scp path
# and verify.sh's final exec).
_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGEMENT_DIR="$(cd "${_COMMON_LIB_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${MANAGEMENT_DIR}/../../.." && pwd)"
CONFIG_FILE="${AKS_MANAGEMENT_CONFIG:-${MANAGEMENT_DIR}/config/platform.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

AKS_MANAGEMENT_SUBSCRIPTION_ID="${AKS_MANAGEMENT_SUBSCRIPTION_ID:-}"
AKS_MANAGEMENT_RESOURCE_GROUP="${AKS_MANAGEMENT_RESOURCE_GROUP:-}"
AKS_MANAGEMENT_LOCATION="${AKS_MANAGEMENT_LOCATION:-southeastasia}"

# Control plane
AKS_MANAGEMENT_CP_VM_NAME="${AKS_MANAGEMENT_CP_VM_NAME:-}"
# Linux hostname / kubeadm --node-name — distinct from AKS_MANAGEMENT_CP_VM_NAME
# (the Azure resource name, e.g. vm-ics-ms-k8s-ops-sgp-001), matching
# terraform's var.control_plane_node_name.
AKS_MANAGEMENT_CP_NODE_NAME="${AKS_MANAGEMENT_CP_NODE_NAME:-k8s-ops-01}"
AKS_MANAGEMENT_CP_PUBLIC_IP="${AKS_MANAGEMENT_CP_PUBLIC_IP:-}"
AKS_MANAGEMENT_CP_PRIVATE_IP="${AKS_MANAGEMENT_CP_PRIVATE_IP:-}"

# Worker
AKS_MANAGEMENT_WORKER_VM_NAME="${AKS_MANAGEMENT_WORKER_VM_NAME:-}"
AKS_MANAGEMENT_WORKER_NODE_NAME="${AKS_MANAGEMENT_WORKER_NODE_NAME:-k8s-worker-01}"
AKS_MANAGEMENT_WORKER_PUBLIC_IP="${AKS_MANAGEMENT_WORKER_PUBLIC_IP:-}"
AKS_MANAGEMENT_WORKER_PRIVATE_IP="${AKS_MANAGEMENT_WORKER_PRIVATE_IP:-}"

AKS_MANAGEMENT_SSH_USER="${AKS_MANAGEMENT_SSH_USER:-azureuser}"
AKS_MANAGEMENT_SSH_KEY_PATH="${AKS_MANAGEMENT_SSH_KEY_PATH:-~/.ssh/id_ed25519}"
AKS_MANAGEMENT_KUBECTL_CONTEXT="${AKS_MANAGEMENT_KUBECTL_CONTEXT:-}"
AKS_MANAGEMENT_CF_TUNNEL_TOKEN="${AKS_MANAGEMENT_CF_TUNNEL_TOKEN:-}"
AKS_MANAGEMENT_RANCHER_HOSTNAME="${AKS_MANAGEMENT_RANCHER_HOSTNAME:-}"
AKS_MANAGEMENT_RANCHER_CHART_VERSION="${AKS_MANAGEMENT_RANCHER_CHART_VERSION:-2.14.3}"
AKS_MANAGEMENT_RANCHER_REPLICAS="${AKS_MANAGEMENT_RANCHER_REPLICAS:-1}"
AKS_MANAGEMENT_CERT_MANAGER_VERSION="${AKS_MANAGEMENT_CERT_MANAGER_VERSION:-1.21.0}"
AKS_MANAGEMENT_EXPECTED_DOWNSTREAMS="${AKS_MANAGEMENT_EXPECTED_DOWNSTREAMS:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

require_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "Create ${CONFIG_FILE} from ${MANAGEMENT_DIR}/config/platform.env.example first."
  [[ -n "${AKS_MANAGEMENT_CP_PUBLIC_IP}" && -n "${AKS_MANAGEMENT_CP_PRIVATE_IP}" \
     && -n "${AKS_MANAGEMENT_WORKER_PUBLIC_IP}" && -n "${AKS_MANAGEMENT_WORKER_PRIVATE_IP}" ]] \
    || die "AKS_MANAGEMENT_CP_*/WORKER_* public/private IPs must be set in ${CONFIG_FILE} (from terraform output)."
}

require_rancher_config() {
  [[ -n "${AKS_MANAGEMENT_RANCHER_HOSTNAME}" && "${AKS_MANAGEMENT_RANCHER_HOSTNAME}" != *"example.com"* ]] \
    || die "Set AKS_MANAGEMENT_RANCHER_HOSTNAME in ${CONFIG_FILE}."
  [[ "${AKS_MANAGEMENT_RANCHER_REPLICAS}" =~ ^[1-9][0-9]*$ ]] \
    || die "AKS_MANAGEMENT_RANCHER_REPLICAS must be a positive integer."
}

# VM-level check (before a Kubernetes cluster exists on it yet) — used by
# preflight.sh and bootstrap-control-plane.sh/bootstrap-worker.sh, distinct
# from require_cluster below. target is "cp" or "worker".
require_ssh() {
  local target="${1:?require_ssh needs \"cp\" or \"worker\"}"
  local ip
  require_config
  case "${target}" in
    cp) ip="${AKS_MANAGEMENT_CP_PUBLIC_IP}" ;;
    worker) ip="${AKS_MANAGEMENT_WORKER_PUBLIC_IP}" ;;
    *) die "require_ssh: unknown target '${target}' (expected cp or worker)" ;;
  esac

  # Each VM's public IP is a static Azure Public IP resource that outlives
  # any single VM behind it — recreating/resizing a VM keeps the same IP but
  # can generate a new SSH host key. Found live: without this, a stale
  # known_hosts entry from a previous VM makes StrictHostKeyChecking=accept-new
  # refuse to connect instead of just trusting the new key, since the IP
  # already has a *different* one on file.
  ssh-keygen -R "${ip}" >/dev/null 2>&1 || true
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -i "${AKS_MANAGEMENT_SSH_KEY_PATH}" \
    "${AKS_MANAGEMENT_SSH_USER}@${ip}" true 2>/dev/null \
    || die "Cannot SSH to ${AKS_MANAGEMENT_SSH_USER}@${ip} (${target}). Check the VM is running and admin_cidr in terraform.tfvars includes your current IP."
}

# Cluster-level check (after kubeadm has run) — used by every script from
# bootstrap.sh onward, same shape as platforms/ack/management's require_cluster.
require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach the management cluster. Run export-kubeconfig.sh first (the API server is only reachable through the SSH tunnel it starts — see main.tf's NSG, which opens no public 6443)."
  if [[ -n "${AKS_MANAGEMENT_KUBECTL_CONTEXT}" ]]; then
    local current_context
    current_context="$(kubectl config current-context 2>/dev/null || true)"
    [[ "${current_context}" == "${AKS_MANAGEMENT_KUBECTL_CONTEXT}" ]] \
      || die "Current kubeconfig context is '${current_context:-none}', expected '${AKS_MANAGEMENT_KUBECTL_CONTEXT}'."
  fi
}
