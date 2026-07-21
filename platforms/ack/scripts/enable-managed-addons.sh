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
echo "  ACK Platform Track - Managed add-on prerequisites"
echo "================================================================"
echo ""
echo "This command intentionally makes no ACK control-plane changes."
echo "Terraform manages the VPA add-on. In the ACK console, open the cluster, then Operations -> Add-ons:"
echo "  1. Confirm CSI plug-in and csi-provisioner are installed."
echo "  2. Confirm ack-vertical-pod-autoscaler is Healthy for Kubernetes 1.26+."
echo "  3. Confirm Terway uses shared ENI mode with NetworkPolicy enabled."
echo "  4. Install ALB Ingress Controller only before the Module 04 adapter."
echo ""

if kubectl api-resources | awk '{print $1}' | grep -qx verticalpodautoscalers; then
  log_ok "VPA API is already available."
else
  log_warn "VPA API is not available yet. Run Terraform apply, wait for the ACK add-on to reconcile, then re-run preflight."
fi
