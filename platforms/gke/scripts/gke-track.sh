#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  check-prerequisites) exec "${SCRIPT_DIR}/check-prerequisites.sh" ;;
  connect) exec "${SCRIPT_DIR}/connect.sh" ;;
  preflight) exec "${SCRIPT_DIR}/preflight.sh" ;;
  enable-managed-addons) exec "${SCRIPT_DIR}/enable-managed-addons.sh" ;;
  deploy-core-workloads) exec "${SCRIPT_DIR}/deploy-core-workloads.sh" ;;
  enable-networking) exec "${SCRIPT_DIR}/enable-networking.sh" ;;
  enable-storage) exec "${SCRIPT_DIR}/enable-storage.sh" ;;
  enable-scaling) exec "${SCRIPT_DIR}/enable-scaling.sh" ;;
  enable-observability) exec "${SCRIPT_DIR}/enable-observability.sh" ;;
  enable-cf-tunnel) exec "${SCRIPT_DIR}/enable-cf-tunnel.sh" ;;
  *)
    cat >&2 <<'EOF'
Usage: gke-track.sh <check-prerequisites|connect|preflight|enable-managed-addons|deploy-core-workloads|enable-networking|enable-storage|enable-scaling|enable-observability>

Modules 02, 04, 05, 06, 07, 08 are all verified live — see
platforms/gke/README.md for the full Foundation runbook and every real
bug found/fixed along the way (Kyverno readiness field, missing
seccompProfile on upstream manifests, GKE's proxy-only-subnet
requirement, GKE health-check-vs-Grafana-redirect mismatch, and more).

Module 03 (secrets) has no dedicated adapter script, but its native
setup.sh needs ONE fixup on GKE — see platforms/gke/README.md for the
exact commands (setup.sh dies partway through on an immutable
StatefulSet field; the fixup applies the two manifests it never
reaches).

enable-backup and the rest of the Module compatibility table are not
written yet: they need a live cluster to verify against (every adapter
above needed at least one real bug fix only discoverable by actually
running it — writing untested guesses now would risk the same kind of
wrong assumption this repo has repeatedly caught and fixed by testing
against a real cluster instead of guessing).
EOF
    exit 1
    ;;
esac
