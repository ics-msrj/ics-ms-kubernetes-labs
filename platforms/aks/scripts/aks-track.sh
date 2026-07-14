#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  connect) exec "${SCRIPT_DIR}/connect.sh" ;;
  preflight) exec "${SCRIPT_DIR}/preflight.sh" ;;
  enable-managed-addons) exec "${SCRIPT_DIR}/enable-managed-addons.sh" ;;
  deploy-core-workloads) exec "${SCRIPT_DIR}/deploy-core-workloads.sh" ;;
  destroy) exec "${SCRIPT_DIR}/destroy.sh" ;;
  *)
    cat >&2 <<'EOF'
Usage: aks-track.sh <connect|preflight|enable-managed-addons|deploy-core-workloads|destroy>

Run connect, preflight, enable-managed-addons, connect, preflight, then deploy-core-workloads.
destroy removes the online-boutique namespace; it does not touch the AKS cluster itself.
EOF
    exit 1
    ;;
esac
