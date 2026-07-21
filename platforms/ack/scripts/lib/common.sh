#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${PLATFORM_DIR}/../.." && pwd)"
CONFIG_FILE="${ACK_PLATFORM_CONFIG:-${PLATFORM_DIR}/config/ack.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

ACK_PROFILE="${ACK_PROFILE:-}"
ACK_REGION="${ACK_REGION:-ap-southeast-5}"
ACK_RESOURCE_GROUP="${ACK_RESOURCE_GROUP:-}"
ACK_CLUSTER_ID="${ACK_CLUSTER_ID:-}"
ACK_CLUSTER_NAME="${ACK_CLUSTER_NAME:-}"
ACK_KUBECTL_CONTEXT="${ACK_KUBECTL_CONTEXT:-}"
ACK_STORAGE_CLASS="${ACK_STORAGE_CLASS:-}"
ACK_REDIS_DISK_SIZE="${ACK_REDIS_DISK_SIZE:-20Gi}"
ACK_WORKLOAD_NODEPOOL="${ACK_WORKLOAD_NODEPOOL:-workloadpool}"
ACK_WORKLOAD_LABEL_KEY="${ACK_WORKLOAD_LABEL_KEY:-workload}"
ACK_WORKLOAD_LABEL_VALUE="${ACK_WORKLOAD_LABEL_VALUE:-autoscale}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

require_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "Create ${CONFIG_FILE} from ${PLATFORM_DIR}/config/ack.env.example first."
  [[ -n "${ACK_PROFILE}" && -n "${ACK_CLUSTER_ID}" && -n "${ACK_CLUSTER_NAME}" ]] \
    || die "ACK_PROFILE, ACK_CLUSTER_ID, and ACK_CLUSTER_NAME must be set in ${CONFIG_FILE}."
}

require_storage_config() {
  [[ -n "${ACK_STORAGE_CLASS}" ]] \
    || die "Set ACK_STORAGE_CLASS in ${CONFIG_FILE} from 'kubectl get storageclass'."
}

require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the configured ACK cluster. Obtain a temporary kubeconfig in the ACK console first."
  if [[ -n "${ACK_KUBECTL_CONTEXT}" ]]; then
    local current_context
    current_context="$(kubectl config current-context 2>/dev/null || true)"
    [[ "${current_context}" == "${ACK_KUBECTL_CONTEXT}" ]] \
      || die "Current kubeconfig context is '${current_context:-none}', expected '${ACK_KUBECTL_CONTEXT}'."
  fi
}

ack_cluster_json() {
  aliyun cs GET "/clusters/${ACK_CLUSTER_ID}" --profile "${ACK_PROFILE}" --region "${ACK_REGION}"
}
