#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGEMENT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${MANAGEMENT_DIR}/../../.." && pwd)"
CONFIG_FILE="${ACK_MANAGEMENT_CONFIG:-${MANAGEMENT_DIR}/config/platform.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

ACK_MANAGEMENT_PROFILE="${ACK_MANAGEMENT_PROFILE:-}"
ACK_MANAGEMENT_REGION="${ACK_MANAGEMENT_REGION:-ap-southeast-5}"
ACK_MANAGEMENT_CLUSTER_ID="${ACK_MANAGEMENT_CLUSTER_ID:-}"
ACK_MANAGEMENT_CLUSTER_NAME="${ACK_MANAGEMENT_CLUSTER_NAME:-}"
ACK_MANAGEMENT_KUBECTL_CONTEXT="${ACK_MANAGEMENT_KUBECTL_CONTEXT:-}"
ACK_MANAGEMENT_CF_TUNNEL_TOKEN="${ACK_MANAGEMENT_CF_TUNNEL_TOKEN:-}"
ACK_MANAGEMENT_RANCHER_HOSTNAME="${ACK_MANAGEMENT_RANCHER_HOSTNAME:-}"
ACK_MANAGEMENT_RANCHER_CHART_VERSION="${ACK_MANAGEMENT_RANCHER_CHART_VERSION:-2.14.3}"
ACK_MANAGEMENT_RANCHER_REPLICAS="${ACK_MANAGEMENT_RANCHER_REPLICAS:-2}"
ACK_MANAGEMENT_CERT_MANAGER_VERSION="${ACK_MANAGEMENT_CERT_MANAGER_VERSION:-1.21.0}"
ACK_MANAGEMENT_EXPECTED_DOWNSTREAMS="${ACK_MANAGEMENT_EXPECTED_DOWNSTREAMS:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

require_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "Create ${CONFIG_FILE} from ${MANAGEMENT_DIR}/config/platform.env.example first."
  [[ -n "${ACK_MANAGEMENT_CLUSTER_ID}" && -n "${ACK_MANAGEMENT_CLUSTER_NAME}" ]] \
    || die "ACK_MANAGEMENT_CLUSTER_ID and ACK_MANAGEMENT_CLUSTER_NAME must be set in ${CONFIG_FILE}."
}

require_rancher_config() {
  [[ -n "${ACK_MANAGEMENT_RANCHER_HOSTNAME}" && "${ACK_MANAGEMENT_RANCHER_HOSTNAME}" != *"example.com"* ]] \
    || die "Set ACK_MANAGEMENT_RANCHER_HOSTNAME in ${CONFIG_FILE}."
  [[ "${ACK_MANAGEMENT_RANCHER_REPLICAS}" =~ ^[1-9][0-9]*$ ]] \
    || die "ACK_MANAGEMENT_RANCHER_REPLICAS must be a positive integer."
}

require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach the management cluster. Obtain a fresh ACK kubeconfig first."
  if [[ -n "${ACK_MANAGEMENT_KUBECTL_CONTEXT}" ]]; then
    local current_context
    current_context="$(kubectl config current-context 2>/dev/null || true)"
    [[ "${current_context}" == "${ACK_MANAGEMENT_KUBECTL_CONTEXT}" ]] \
      || die "Current kubeconfig context is '${current_context:-none}', expected '${ACK_MANAGEMENT_KUBECTL_CONTEXT}'."
  fi
}
