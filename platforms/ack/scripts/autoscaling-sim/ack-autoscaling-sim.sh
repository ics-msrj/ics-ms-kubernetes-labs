#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  preflight) exec "${SCRIPT_DIR}/preflight.sh" ;;
  apply) exec "${SCRIPT_DIR}/apply.sh" ;;
  baseline) exec "${SCRIPT_DIR}/run-load.sh" baseline ;;
  vpa-check) exec "${SCRIPT_DIR}/vpa-check.sh" ;;
  enable-hpa) exec "${SCRIPT_DIR}/enable-hpa.sh" ;;
  gradual) exec "${SCRIPT_DIR}/run-load.sh" gradual ;;
  spike) exec "${SCRIPT_DIR}/run-load.sh" spike ;;
  watch) exec "${SCRIPT_DIR}/watch-scaling.sh" ;;
  cleanup) exec "${SCRIPT_DIR}/cleanup.sh" ;;
  *)
    cat >&2 <<'EOF'
Usage: ack-autoscaling-sim.sh <preflight|apply|baseline|vpa-check|enable-hpa|gradual|spike|watch|cleanup>

Run baseline and vpa-check before enable-hpa. Review the VPA recommendation and
set ACK_SIM_VPA_REVIEWED=true before either traffic profile.
EOF
    exit 1
    ;;
esac
