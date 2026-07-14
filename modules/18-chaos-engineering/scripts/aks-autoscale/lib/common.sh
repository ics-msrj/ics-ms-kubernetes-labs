#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${AKS_AUTOSCALE_SIM_CONFIG:-${MODULE_DIR}/config/aks-autoscale-sim.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

NAMESPACE="${NAMESPACE:-autoscale-sim}"
AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-}"
WORKLOAD_NODEPOOL="${WORKLOAD_NODEPOOL:-workloadpool}"
WORKLOAD_NODE_LABEL_KEY="${WORKLOAD_NODE_LABEL_KEY:-workload}"
WORKLOAD_NODE_LABEL_VALUE="${WORKLOAD_NODE_LABEL_VALUE:-autoscale}"
MIN_NODES="${MIN_NODES:-1}"
MAX_NODES="${MAX_NODES:-3}"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
MAX_REPLICAS="${MAX_REPLICAS:-12}"
PROMETHEUS_NAMESPACE="${PROMETHEUS_NAMESPACE:-monitoring}"
PROMETHEUS_SERVICE="${PROMETHEUS_SERVICE:-monitoring-kube-prometheus-prometheus}"
OPENCOST_NAMESPACE="${OPENCOST_NAMESPACE:-opencost}"
OPENCOST_SERVICE="${OPENCOST_SERVICE:-opencost}"
REQUIRE_OPENCOST="${REQUIRE_OPENCOST:-false}"
# shellcheck disable=SC2034 # Consumed by apply.sh after sourcing this library.
MANIFEST_DIR="${MODULE_DIR}/manifests/aks-autoscale"
ARTIFACT_ROOT="${MODULE_DIR}/artifacts"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { log_error "$*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_cluster() { kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the target cluster."; }
require_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "Create ${CONFIG_FILE} from ${CONFIG_FILE}.example first."
  [[ -n "${AKS_RESOURCE_GROUP}" && -n "${AKS_CLUSTER_NAME}" ]] || die "AKS_RESOURCE_GROUP and AKS_CLUSTER_NAME must be set."
  [[ "${WORKLOAD_NODE_LABEL_KEY}" == "workload" && "${WORKLOAD_NODE_LABEL_VALUE}" == "autoscale" ]] || die "This lab reserves workload=autoscale for its dedicated workload pool; do not retarget it."
}
new_artifact_dir() {
  local scenario="$1"
  RUN_ARTIFACT_DIR="${ARTIFACT_ROOT}/$(date -u +%Y-%m-%dT%H%M%SZ)-${scenario}"
  mkdir -p "${RUN_ARTIFACT_DIR}"
  export RUN_ARTIFACT_DIR
}
