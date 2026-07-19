#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC2034 # Consumed by deploy-core-workloads.sh after sourcing this library.
REPO_ROOT="$(cd "${PLATFORM_DIR}/../.." && pwd)"
CONFIG_FILE="${AKS_PLATFORM_CONFIG:-${PLATFORM_DIR}/config/aks.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-}"
AKS_SUBSCRIPTION_ID="${AKS_SUBSCRIPTION_ID:-}"
AKS_WORKLOAD_NODEPOOL="${AKS_WORKLOAD_NODEPOOL:-workloadpool}"
AKS_STORAGE_CLASS="${AKS_STORAGE_CLASS:-managed-csi}"
AKS_WORKLOAD_LABEL_KEY="${AKS_WORKLOAD_LABEL_KEY:-workload}"
AKS_WORKLOAD_LABEL_VALUE="${AKS_WORKLOAD_LABEL_VALUE:-autoscale}"

# Every script sourcing this library gets the correct subscription pinned
# for its `az` calls — without this, they silently follow whatever
# subscription `az account show` currently defaults to, which drifted mid
# this project (Terraform's provider had the identical problem; see
# platforms/aks/terraform/variables.tf's subscription_id for the same fix).
if [[ -n "${AKS_SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "${AKS_SUBSCRIPTION_ID}" 2>/dev/null \
    || { echo -e "\033[0;31m[ERROR]\033[0m Failed to set az subscription to ${AKS_SUBSCRIPTION_ID}. Run 'az login' first." >&2; exit 1; }
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "Create ${CONFIG_FILE} from ${PLATFORM_DIR}/config/aks.env.example first."
  [[ -n "${AKS_RESOURCE_GROUP}" && -n "${AKS_CLUSTER_NAME}" ]] || die "AKS_RESOURCE_GROUP and AKS_CLUSTER_NAME must be set."
}
require_cluster() { kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the configured AKS cluster. Run connect.sh first."; }
