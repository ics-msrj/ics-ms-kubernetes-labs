#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  connect) exec "${SCRIPT_DIR}/connect.sh" ;;
  preflight) exec "${SCRIPT_DIR}/preflight.sh" ;;
  enable-managed-addons) exec "${SCRIPT_DIR}/enable-managed-addons.sh" ;;
  deploy-core-workloads) exec "${SCRIPT_DIR}/deploy-core-workloads.sh" ;;
  enable-networking) exec "${SCRIPT_DIR}/enable-networking.sh" ;;
  destroy) exec "${SCRIPT_DIR}/destroy.sh" ;;
  *)
    cat >&2 <<'EOF'
Usage: aks-track.sh <connect|preflight|enable-managed-addons|deploy-core-workloads|enable-networking|destroy>

Run connect, preflight, enable-managed-addons, connect, preflight, deploy-core-workloads,
then enable-networking (Module 04 equivalent — Gateway, cert-manager, HTTPS).
destroy removes the online-boutique namespace; it does not touch the AKS cluster itself.
EOF
    exit 1
    ;;
esac
