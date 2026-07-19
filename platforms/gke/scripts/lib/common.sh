#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC2034 # Consumed by deploy-core-workloads.sh after sourcing this library.
REPO_ROOT="$(cd "${PLATFORM_DIR}/../.." && pwd)"
CONFIG_FILE="${GKE_PLATFORM_CONFIG:-${PLATFORM_DIR}/config/gke.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

GKE_PROJECT_ID="${GKE_PROJECT_ID:-}"
GKE_REGION="${GKE_REGION:-asia-southeast1}"
GKE_ZONE="${GKE_ZONE:-asia-southeast1-a}"
GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-}"
GKE_WORKLOAD_NODEPOOL="${GKE_WORKLOAD_NODEPOOL:-workloadpool}"
GKE_STORAGE_CLASS="${GKE_STORAGE_CLASS:-standard-rwo}"
GKE_WORKLOAD_LABEL_KEY="${GKE_WORKLOAD_LABEL_KEY:-workload}"
GKE_WORKLOAD_LABEL_VALUE="${GKE_WORKLOAD_LABEL_VALUE:-autoscale}"

# Every script sourcing this library gets the correct project pinned for
# its `gcloud` calls — without this, they silently follow whatever
# project `gcloud config get-value project` currently defaults to, the
# same drift-between-runs failure mode the AKS track's az account set
# pinning (and this track's own Terraform provider) exists to avoid.
if [[ -n "${GKE_PROJECT_ID}" ]]; then
  gcloud config set project "${GKE_PROJECT_ID}" >/dev/null 2>&1 \
    || { echo -e "\033[0;31m[ERROR]\033[0m Failed to set gcloud project to ${GKE_PROJECT_ID}. Run 'gcloud auth login' first." >&2; exit 1; }
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "Create ${CONFIG_FILE} from ${PLATFORM_DIR}/config/gke.env.example first."
  [[ -n "${GKE_PROJECT_ID}" && -n "${GKE_CLUSTER_NAME}" ]] || die "GKE_PROJECT_ID and GKE_CLUSTER_NAME must be set."
}
require_cluster() { kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the configured GKE cluster. Run connect.sh first."; }
