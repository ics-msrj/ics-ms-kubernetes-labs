#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_config
require_cluster
[[ -n "${ACK_MANAGEMENT_CF_TUNNEL_TOKEN}" ]] \
  || die "Set ACK_MANAGEMENT_CF_TUNNEL_TOKEN in ${CONFIG_FILE}."

kubectl create namespace cloudflare-tunnel --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic cloudflared-token --namespace cloudflare-tunnel \
  --from-literal="TUNNEL_TOKEN=${ACK_MANAGEMENT_CF_TUNNEL_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${MANAGEMENT_DIR}/manifests/cloudflare/cloudflared-deployment.yaml"
kubectl rollout status deployment/cloudflared -n cloudflare-tunnel --timeout=180s

registered=true
for pod in $(kubectl get pods -n cloudflare-tunnel -l app=cloudflared -o jsonpath='{.items[*].metadata.name}'); do
  kubectl logs -n cloudflare-tunnel "${pod}" --tail=200 | grep -qi "Registered tunnel connection" || registered=false
done

if [[ "${registered}" == true ]]; then
  log_ok "Every cloudflared replica registered a tunnel connection."
else
  log_warn "Connector rollout is ready, but registration is still pending. Check cloudflared logs."
fi

echo ""
echo "Next: bash platforms/ack/management/scripts/platform-track.sh enable-rancher"
