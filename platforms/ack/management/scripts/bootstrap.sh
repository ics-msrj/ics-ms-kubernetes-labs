#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config
require_cluster

echo ""
echo "================================================================"
echo "  ACK Rancher Management Cluster - Bootstrap"
echo "================================================================"
echo ""

kubectl apply -f "${MANAGEMENT_DIR}/manifests/bootstrap/namespaces.yaml"
log_ok "Management namespaces created"

NODE_COUNT="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
if (( NODE_COUNT < 3 )); then
  die "Expected at least three management nodes, found ${NODE_COUNT}."
fi

log_ok "Management cluster baseline is ready"
echo ""
echo "Next: bash platforms/ack/management/scripts/platform-track.sh enable-cloudflare"
