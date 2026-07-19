#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command gcloud
require_command kubectl
require_config

gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q . \
  || die "No active gcloud account. Run 'gcloud auth login' first."
log_info "Merging credentials for ${GKE_CLUSTER_NAME} into the local kubeconfig..."
gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" --zone "${GKE_ZONE}" --project "${GKE_PROJECT_ID}"
require_cluster
log_ok "Connected to GKE cluster ${GKE_CLUSTER_NAME}."
