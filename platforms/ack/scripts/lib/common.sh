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
ACK_GITOPS_REPO_URL="${ACK_GITOPS_REPO_URL:-}"
ACK_GITOPS_REPO_REVISION="${ACK_GITOPS_REPO_REVISION:-main}"
ACK_ARGOCD_HOSTNAME="${ACK_ARGOCD_HOSTNAME:-}"
ACK_RANCHER_HOSTNAME="${ACK_RANCHER_HOSTNAME:-}"
ACK_RANCHER_CHART_VERSION="${ACK_RANCHER_CHART_VERSION:-2.14.3}"
ACK_RANCHER_REPLICAS="${ACK_RANCHER_REPLICAS:-2}"
ACK_RANCHER_EXPECTED_DOWNSTREAMS="${ACK_RANCHER_EXPECTED_DOWNSTREAMS:-}"
ACK_BACKUP_BUCKET="${ACK_BACKUP_BUCKET:-}"
ACK_BACKUP_LOCATION="${ACK_BACKUP_LOCATION:-ack-backup}"
ACK_BACKUP_PREFIX="${ACK_BACKUP_PREFIX:-${ACK_CLUSTER_NAME}/module-13}"
ACK_BACKUP_TTL="${ACK_BACKUP_TTL:-720h0m0s}"
ACK_BACKUP_NAMESPACE="${ACK_BACKUP_NAMESPACE:-online-boutique}"
ACK_RESTORE_NAMESPACE="${ACK_RESTORE_NAMESPACE:-online-boutique-restore-drill}"
ACK_BACKUP_WAIT_TIMEOUT_SECONDS="${ACK_BACKUP_WAIT_TIMEOUT_SECONDS:-1800}"

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

require_gitops_config() {
  [[ -n "${ACK_GITOPS_REPO_URL}" && "${ACK_GITOPS_REPO_URL}" != *"<you>"* ]] \
    || die "Set ACK_GITOPS_REPO_URL in ${CONFIG_FILE} to the Git remote ArgoCD will clone."
  [[ -n "${ACK_ARGOCD_HOSTNAME}" ]] \
    || die "Set ACK_ARGOCD_HOSTNAME in ${CONFIG_FILE} to the Cloudflare Tunnel public hostname."
}

require_rancher_config() {
  [[ -n "${ACK_RANCHER_HOSTNAME}" && "${ACK_RANCHER_HOSTNAME}" != *"example.com"* ]] \
    || die "Set ACK_RANCHER_HOSTNAME in ${CONFIG_FILE} to the Cloudflare Tunnel public hostname."
  [[ "${ACK_RANCHER_REPLICAS}" =~ ^[1-9][0-9]*$ ]] \
    || die "ACK_RANCHER_REPLICAS must be a positive integer in ${CONFIG_FILE}."
}

require_backup_config() {
  [[ -n "${ACK_BACKUP_BUCKET}" ]] \
    || die "Set ACK_BACKUP_BUCKET in ${CONFIG_FILE} to the pre-created cnfs-oss-* bucket."
  [[ "${ACK_BACKUP_BUCKET}" == cnfs-oss-* ]] \
    || die "ACK_BACKUP_BUCKET must start with cnfs-oss- for ACK Backup Center."
  [[ -n "${ACK_BACKUP_LOCATION}" && -n "${ACK_BACKUP_PREFIX}" ]] \
    || die "Set ACK_BACKUP_LOCATION and ACK_BACKUP_PREFIX in ${CONFIG_FILE}."
  [[ "${ACK_BACKUP_NAMESPACE}" != "${ACK_RESTORE_NAMESPACE}" ]] \
    || die "ACK_RESTORE_NAMESPACE must differ from ACK_BACKUP_NAMESPACE."
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
