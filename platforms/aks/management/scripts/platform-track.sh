#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  preflight) exec "${SCRIPT_DIR}/preflight.sh" ;;
  bootstrap-control-plane) exec "${SCRIPT_DIR}/bootstrap-control-plane.sh" ;;
  bootstrap-worker) exec "${SCRIPT_DIR}/bootstrap-worker.sh" ;;
  export-kubeconfig) exec "${SCRIPT_DIR}/export-kubeconfig.sh" ;;
  bootstrap) exec "${SCRIPT_DIR}/bootstrap.sh" ;;
  enable-cloudflare) exec "${SCRIPT_DIR}/enable-cloudflare.sh" ;;
  enable-rancher) exec "${SCRIPT_DIR}/enable-rancher.sh" ;;
  verify-rancher) exec "${SCRIPT_DIR}/verify-rancher.sh" ;;
  verify) exec "${SCRIPT_DIR}/verify.sh" ;;
  cleanup-rancher) exec "${SCRIPT_DIR}/cleanup-rancher.sh" ;;
  *)
    cat >&2 <<'EOF'
Usage: platform-track.sh <preflight|bootstrap-control-plane|bootstrap-worker|export-kubeconfig|bootstrap|enable-cloudflare|enable-rancher|verify-rancher|verify|cleanup-rancher>

Run terraform (../terraform/) first, then in order: preflight,
bootstrap-control-plane (installs kubeadm+Cilium on the control-plane VM over
SSH, fetches the worker join command), bootstrap-worker (joins the worker VM
to the cluster), export-kubeconfig (starts the SSH tunnel to the
control-plane this track uses instead of a public 6443), bootstrap,
enable-cloudflare, and enable-rancher. Import downstream clusters manually in
Rancher before verification.
EOF
    exit 1
    ;;
esac
