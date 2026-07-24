#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  preflight) exec "${SCRIPT_DIR}/preflight.sh" ;;
  bootstrap) exec "${SCRIPT_DIR}/bootstrap.sh" ;;
  enable-cloudflare) exec "${SCRIPT_DIR}/enable-cloudflare.sh" ;;
  enable-rancher) exec "${SCRIPT_DIR}/enable-rancher.sh" ;;
  verify-rancher) exec "${SCRIPT_DIR}/verify-rancher.sh" ;;
  verify) exec "${SCRIPT_DIR}/verify.sh" ;;
  cleanup-rancher) exec "${SCRIPT_DIR}/cleanup-rancher.sh" ;;
  *)
    cat >&2 <<'EOF'
Usage: platform-track.sh <preflight|bootstrap|enable-cloudflare|enable-rancher|verify-rancher|verify|cleanup-rancher>

This track targets only ack-nextops-platform-jkt-001. It does not deploy to
the existing ACK workload cluster. Run Terraform first, then preflight,
bootstrap, enable-cloudflare, and enable-rancher. Import downstream clusters
manually in Rancher before verification.
EOF
    exit 1
    ;;
esac
