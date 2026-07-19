#!/usr/bin/env bash
# =============================================================================
# GKE Platform Track — enable-cf-tunnel.sh
#
# Runs Cloudflare Tunnel connector pods in-cluster, authenticated with a
# tunnel token generated in the Cloudflare Zero Trust dashboard. Identical
# purpose and mechanism to the AKS track's own enable-cf-tunnel.sh — an
# alternative ingress path to enable-networking.sh's public GCP Load
# Balancer + cert-manager/ACME setup.
#
# Public-hostname routing (which Cloudflare hostname maps to which internal
# Service/URL) is dashboard-side config on the tunnel this token belongs to
# — not something this script or the manifest it applies configures.
#
# CF_TUNNEL_TOKEN is never written to any committed file. It's read from
# gke.env (gitignored) and only ever lands in a live Kubernetes Secret.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"

require_command kubectl
require_cluster
[[ -n "$CF_TUNNEL_TOKEN" ]] || die "Set CF_TUNNEL_TOKEN in platforms/gke/config/gke.env first."

echo ""
echo "================================================================"
echo "  GKE Platform Track — Cloudflare Tunnel"
echo "================================================================"
echo ""

log_info "Creating namespace and sealing the tunnel token into a Secret..."
kubectl create namespace cloudflare-tunnel --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic cloudflared-token \
  --namespace cloudflare-tunnel \
  --from-literal=TUNNEL_TOKEN="${CF_TUNNEL_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
log_ok "Secret applied"

log_info "Deploying cloudflared connector (2 replicas, spread across nodes)..."
kubectl apply -f "${PLATFORM_DIR}/manifests/cloudflared-deployment.yaml"
kubectl rollout status deployment/cloudflared -n cloudflare-tunnel --timeout=120s
log_ok "cloudflared ready"

log_info "Checking connector logs for a registered tunnel connection..."
sleep 10
ALL_REGISTERED=true
for pod in $(kubectl get pods -n cloudflare-tunnel -l app=cloudflared -o jsonpath='{.items[*].metadata.name}'); do
  kubectl logs -n cloudflare-tunnel "$pod" --tail=200 | grep -qi "Registered tunnel connection" || ALL_REGISTERED=false
done
if [[ "$ALL_REGISTERED" == "true" ]]; then
  log_ok "Tunnel connection registered on every replica"
else
  log_warn "Not every replica has registered yet — check: kubectl logs -n cloudflare-tunnel -l app=cloudflared"
fi

echo ""
echo "================================================================"
echo "  Cloudflare Tunnel connector ready."
echo "  Public-hostname routing is configured in the Cloudflare Zero"
echo "  Trust dashboard for this tunnel, not here."
echo "  Logs: kubectl logs -n cloudflare-tunnel -l app=cloudflared -f"
echo "================================================================"
echo ""
