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
  enable-backup) exec "${SCRIPT_DIR}/enable-backup.sh" ;;
  enable-multicluster) exec "${SCRIPT_DIR}/enable-multicluster.sh" ;;
  promote-canary) exec "${SCRIPT_DIR}/promote-canary.sh" ;;
  enable-observability) exec "${SCRIPT_DIR}/enable-observability.sh" ;;
  enable-servicemesh) exec "${SCRIPT_DIR}/enable-servicemesh.sh" ;;
  enable-cf-tunnel) exec "${SCRIPT_DIR}/enable-cf-tunnel.sh" ;;
  verify) exec "${SCRIPT_DIR}/verify.sh" ;;
  destroy) exec "${SCRIPT_DIR}/destroy.sh" ;;
  *)
    cat >&2 <<'EOF'
Usage: aks-track.sh <check-prerequisites|connect|preflight|enable-managed-addons|deploy-core-workloads|enable-secrets|enable-networking|enable-storage|enable-scaling|enable-backup|enable-observability|enable-servicemesh|enable-cf-tunnel|enable-multicluster|promote-canary|verify|destroy>

Run connect, preflight, enable-managed-addons, connect, preflight, deploy-core-workloads,
enable-secrets (Module 03), enable-networking (Module 04), enable-storage (Module 05),
enable-scaling (Module 07), enable-backup (Module 13), enable-observability (Module 08).
enable-secrets uses Key Vault Secrets Provider instead of Sealed Secrets when
AKS_KEY_VAULT_NAME is set in aks.env — otherwise run Module 03's own native
setup.sh instead (same as this track's other fully-unmodified modules).
enable-servicemesh (Module 17) needs Module 12's native setup.sh run first.
enable-cf-tunnel is optional — runs Cloudflare Tunnel connector pods as an
alternative ingress path, needs CF_TUNNEL_TOKEN set in aks.env.
enable-multicluster and promote-canary are Module 14's equivalent — optional,
needs a second AKS cluster (see platforms/aks/terraform/).
destroy removes the online-boutique/velero/cattle-system namespaces; it does
not touch the AKS cluster itself.
EOF
    exit 1
    ;;
esac
