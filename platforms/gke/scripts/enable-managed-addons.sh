#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command gcloud
require_config

echo "This enables GKE-managed VPA and the GKE Gateway controller (standard channel)."
echo "It does not change node-pool size or deploy application workloads."
echo ""
echo "Note: unlike AKS's managed KEDA add-on, GKE has no managed KEDA — Module"
echo "07's own native setup.sh (self-installed KEDA via Helm) is still needed"
echo "for ScaledObject support, verified by reading GKE's add-on list, not"
echo "assumed."
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

# Two separate calls, not one combined command — gcloud rejects
# --enable-vertical-pod-autoscaling and --gateway-api together ("Exactly
# one of (...) must be specified"), a mutually-exclusive-group constraint
# on `gcloud container clusters update`, confirmed by actually running it.
log_info "Enabling Vertical Pod Autoscaling..."
gcloud container clusters update "${GKE_CLUSTER_NAME}" \
  --zone "${GKE_ZONE}" \
  --project "${GKE_PROJECT_ID}" \
  --enable-vertical-pod-autoscaling

log_info "Enabling the GKE Gateway controller (standard channel)..."
gcloud container clusters update "${GKE_CLUSTER_NAME}" \
  --zone "${GKE_ZONE}" \
  --project "${GKE_PROJECT_ID}" \
  --gateway-api=standard

log_ok "Managed add-ons enabled. Run connect.sh and preflight.sh after the update finishes."
