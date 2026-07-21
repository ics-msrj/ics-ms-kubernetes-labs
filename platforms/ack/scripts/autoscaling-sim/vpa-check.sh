#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_sim_config
require_cluster

mode="$(kubectl -n "${NAMESPACE}" get vpa autoscale-target -o jsonpath='{.spec.updatePolicy.updateMode}')"
[[ "${mode}" == "Off" ]] || die "VPA must remain Off while HPA manages CPU replicas; found ${mode}."
recommendation="$(kubectl -n "${NAMESPACE}" get vpa autoscale-target \
  -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}' 2>/dev/null || true)"
if [[ -n "${recommendation}" ]]; then
  log_ok "VPA is Off and recommends ${recommendation} CPU. Review it before setting ACK_SIM_VPA_REVIEWED=true."
else
  log_warn "VPA is Off but has no recommendation yet. Run the baseline profile and allow the recommender to observe it."
fi
