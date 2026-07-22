#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  check-prerequisites) exec "${SCRIPT_DIR}/check-prerequisites.sh" ;;
  connect) exec "${SCRIPT_DIR}/connect.sh" ;;
  preflight) exec "${SCRIPT_DIR}/preflight.sh" ;;
  enable-managed-addons) exec "${SCRIPT_DIR}/enable-managed-addons.sh" ;;
  deploy-core-workloads) exec "${SCRIPT_DIR}/deploy-core-workloads.sh" ;;
  enable-secrets) exec "${SCRIPT_DIR}/enable-secrets.sh" ;;
  enable-networking) exec "${SCRIPT_DIR}/enable-networking.sh" ;;
  enable-storage) exec "${SCRIPT_DIR}/enable-storage.sh" ;;
  enable-scaling) exec "${SCRIPT_DIR}/enable-scaling.sh" ;;
  enable-observability) exec "${SCRIPT_DIR}/enable-observability.sh" ;;
  enable-logging) exec "${SCRIPT_DIR}/enable-logging.sh" ;;
  enable-packages) exec "${SCRIPT_DIR}/enable-packages.sh" ;;
  verify-packages) exec "${SCRIPT_DIR}/verify-packages.sh" ;;
  enable-gitops) exec "${SCRIPT_DIR}/enable-gitops.sh" ;;
  verify-gitops) exec "${SCRIPT_DIR}/verify-gitops.sh" ;;
  enable-backup) exec "${SCRIPT_DIR}/enable-backup.sh" ;;
  verify-backup) exec "${SCRIPT_DIR}/verify-backup.sh" ;;
  enable-cf-tunnel) exec "${SCRIPT_DIR}/enable-cf-tunnel.sh" ;;
  autoscaling-sim) shift; exec "${SCRIPT_DIR}/autoscaling-sim/ack-autoscaling-sim.sh" "$@" ;;
  verify) exec "${SCRIPT_DIR}/verify.sh" ;;
  destroy) exec "${SCRIPT_DIR}/destroy.sh" ;;
  *)
    cat >&2 <<'EOF'
Usage: ack-track.sh <check-prerequisites|connect|preflight|enable-managed-addons|deploy-core-workloads|enable-secrets|enable-networking|enable-storage|enable-scaling|enable-observability|enable-logging|enable-packages|verify-packages|enable-gitops|verify-gitops|enable-backup|verify-backup|enable-cf-tunnel|autoscaling-sim|verify|destroy> [simulation-action]

Run check-prerequisites, obtain a temporary kubeconfig through the ACK
console, then run connect and preflight. The ACK parity path covers provider-
specific responsibilities through Module 13 where an entrypoint exists.
enable-networking requires the
console-managed ALB Ingress Controller v2.17+ and GatewayClass `alb`.
enable-backup is the Module 13 equivalent; it uses Velero, MinIO, ACK CSI
snapshots, and a workload-node drain drill. autoscaling-sim is isolated from
the curriculum deployment path.
EOF
    exit 1
    ;;
esac
