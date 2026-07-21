#!/usr/bin/env bash

set -euo pipefail

SIM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SIM_LIB_DIR}/../../.." && pwd)"
CALLER_SCRIPT_DIR="${SCRIPT_DIR:-}"
# shellcheck disable=SC1091
source "${PLATFORM_DIR}/scripts/lib/common.sh"
# The shared helper sets SCRIPT_DIR for its own location. Restore the caller's
# directory so sibling simulation scripts can resolve their helper commands.
SCRIPT_DIR="${CALLER_SCRIPT_DIR}"

SIM_CONFIG_FILE="${ACK_AUTOSCALE_SIM_CONFIG:-${PLATFORM_DIR}/config/autoscale-sim.env}"
if [[ -f "${SIM_CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${SIM_CONFIG_FILE}"
fi

NAMESPACE="ack-autoscale-sim"
MANIFEST_DIR="${PLATFORM_DIR}/manifests/autoscaling-sim"
ARTIFACT_ROOT="${PLATFORM_DIR}/artifacts/autoscale-sim"

ACK_SIM_MIN_NODES="${ACK_SIM_MIN_NODES:-1}"
ACK_SIM_MAX_NODES="${ACK_SIM_MAX_NODES:-4}"
ACK_SIM_MIN_REPLICAS="${ACK_SIM_MIN_REPLICAS:-1}"
ACK_SIM_MAX_REPLICAS="${ACK_SIM_MAX_REPLICAS:-12}"
ACK_SIM_HPA_CPU_TARGET="${ACK_SIM_HPA_CPU_TARGET:-70}"
ACK_SIM_TARGET_CPU_REQUEST="${ACK_SIM_TARGET_CPU_REQUEST:-750m}"
ACK_SIM_TARGET_MEMORY_REQUEST="${ACK_SIM_TARGET_MEMORY_REQUEST:-256Mi}"
ACK_SIM_TARGET_CPU_LIMIT="${ACK_SIM_TARGET_CPU_LIMIT:-1500m}"
ACK_SIM_TARGET_MEMORY_LIMIT="${ACK_SIM_TARGET_MEMORY_LIMIT:-512Mi}"
ACK_SIM_CPU_WORK_MS="${ACK_SIM_CPU_WORK_MS:-45}"
ACK_SIM_VPA_REVIEWED="${ACK_SIM_VPA_REVIEWED:-false}"

require_sim_config() {
  require_config
  [[ -f "${SIM_CONFIG_FILE}" ]] \
    || die "Create ${SIM_CONFIG_FILE} from ${PLATFORM_DIR}/config/autoscale-sim.env.example first."
  [[ "${ACK_SIM_MIN_NODES}" =~ ^[1-9][0-9]*$ && "${ACK_SIM_MAX_NODES}" =~ ^[1-9][0-9]*$ ]] \
    || die "ACK_SIM_MIN_NODES and ACK_SIM_MAX_NODES must be positive integers."
  (( ACK_SIM_MIN_NODES <= ACK_SIM_MAX_NODES )) \
    || die "ACK_SIM_MIN_NODES cannot exceed ACK_SIM_MAX_NODES."
  [[ "${ACK_SIM_MIN_REPLICAS}" =~ ^[1-9][0-9]*$ && "${ACK_SIM_MAX_REPLICAS}" =~ ^[1-9][0-9]*$ ]] \
    || die "ACK_SIM_MIN_REPLICAS and ACK_SIM_MAX_REPLICAS must be positive integers."
  (( ACK_SIM_MIN_REPLICAS <= ACK_SIM_MAX_REPLICAS )) \
    || die "ACK_SIM_MIN_REPLICAS cannot exceed ACK_SIM_MAX_REPLICAS."
}

ack_nodepools_json() {
  aliyun cs GET "/clusters/${ACK_CLUSTER_ID}/nodepools" \
    --profile "${ACK_PROFILE}" --region "${ACK_REGION}"
}

new_artifact_dir() {
  local scenario="$1"
  RUN_ARTIFACT_DIR="${ARTIFACT_ROOT}/$(date -u +%Y-%m-%dT%H%M%SZ)-${scenario}"
  mkdir -p "${RUN_ARTIFACT_DIR}"
  export RUN_ARTIFACT_DIR
}
