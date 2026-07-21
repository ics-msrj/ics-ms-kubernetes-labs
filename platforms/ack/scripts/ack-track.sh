#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  check-prerequisites) exec "${SCRIPT_DIR}/check-prerequisites.sh" ;;
  connect) exec "${SCRIPT_DIR}/connect.sh" ;;
  preflight) exec "${SCRIPT_DIR}/preflight.sh" ;;
  enable-managed-addons) exec "${SCRIPT_DIR}/enable-managed-addons.sh" ;;
  deploy-core-workloads) exec "${SCRIPT_DIR}/deploy-core-workloads.sh" ;;
  enable-storage) exec "${SCRIPT_DIR}/enable-storage.sh" ;;
  enable-scaling) exec "${SCRIPT_DIR}/enable-scaling.sh" ;;
  verify) exec "${SCRIPT_DIR}/verify.sh" ;;
  destroy) exec "${SCRIPT_DIR}/destroy.sh" ;;
  *)
    cat >&2 <<'EOF'
Usage: ack-track.sh <check-prerequisites|connect|preflight|enable-managed-addons|deploy-core-workloads|enable-storage|enable-scaling|verify|destroy>

Run check-prerequisites, obtain a temporary kubeconfig through the ACK
console, then run connect and preflight. enable-managed-addons validates the
console-managed VPA prerequisite. The initial implementation covers Modules
02, 05, and 07 only; later adapters require live ACK validation first.
EOF
    exit 1
    ;;
esac
