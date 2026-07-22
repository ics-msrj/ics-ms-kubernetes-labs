#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_command kubectl
require_command curl
require_gitops_config
require_cluster

APP_DOMAIN_OVERRIDE="${APP_DOMAIN:-}" \
ARGOCD_DOMAIN_OVERRIDE="${ACK_ARGOCD_HOSTNAME}" \
ARGOCD_EXPOSURE="cloudflare-tunnel" \
  bash "${REPO_ROOT}/modules/11-gitops-cicd/scripts/verify.sh"
