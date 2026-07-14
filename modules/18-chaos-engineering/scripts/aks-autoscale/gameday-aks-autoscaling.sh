#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION="${1:-}"
case "${ACTION}" in
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
Usage: gameday-aks-autoscaling.sh <preflight|apply|baseline|vpa-check|enable-hpa|gradual|spike|watch|cleanup>

Run the baseline and vpa-check before enable-hpa. Run enable-hpa before either traffic profile.
EOF
    exit 1
    ;;
esac
