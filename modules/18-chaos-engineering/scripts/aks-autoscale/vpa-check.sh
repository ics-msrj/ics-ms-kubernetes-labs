#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_cluster

MODE=$(kubectl -n "${NAMESPACE}" get vpa autoscale-target -o jsonpath='{.spec.updatePolicy.updateMode}')
[[ "${MODE}" == "Off" ]] || die "VPA must remain in Off mode while HPA manages CPU replicas; found ${MODE}."
RECOMMENDATION=$(kubectl -n "${NAMESPACE}" get vpa autoscale-target -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}' 2>/dev/null || true)
if [[ -n "${RECOMMENDATION}" ]]; then
  log_ok "VPA is Off and has a CPU recommendation of ${RECOMMENDATION}. Review it before changing requests."
else
  log_warn "VPA is Off but has no recommendation yet. Run representative load and wait for VPA recommender data."
fi
