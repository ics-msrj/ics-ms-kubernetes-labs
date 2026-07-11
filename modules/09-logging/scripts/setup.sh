#!/bin/bash
# =============================================================================
# Module 09 — Logging — setup.sh
#
# 1. Installs Loki (SingleBinary mode, filesystem storage on a Longhorn PVC)
# 2. Installs Grafana Alloy (DaemonSet) shipping every pod's logs,
#    cluster-wide, to Loki via the Kubernetes API (no hostPath needed)
# 3. Wires Loki into Module 08's existing Grafana as a datasource
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"

LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-7.0.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.10.1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} kubectl cannot reach a cluster. Complete Module 01 first." >&2
  exit 1
fi
if ! kubectl get namespace monitoring &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Namespace monitoring not found. Complete Module 08 first." >&2
  exit 1
fi
if ! kubectl get storageclass longhorn &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} StorageClass longhorn not found. Complete Module 05 first." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "  Module 09 — Logging — Setup"
echo "============================================================"
echo ""

# --- Step 1: Loki ---
log_info "Installing Loki v${LOKI_CHART_VERSION} (SingleBinary, filesystem storage on Longhorn)..."
helm repo add grafana https://grafana.github.io/helm-charts &>/dev/null || true
helm repo update grafana &>/dev/null
helm upgrade --install loki grafana/loki \
  --version "${LOKI_CHART_VERSION}" \
  --namespace monitoring \
  --set deploymentMode=SingleBinary \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set 'loki.schemaConfig.configs[0].from=2024-01-01' \
  --set 'loki.schemaConfig.configs[0].store=tsdb' \
  --set 'loki.schemaConfig.configs[0].object_store=filesystem' \
  --set 'loki.schemaConfig.configs[0].schema=v13' \
  --set 'loki.schemaConfig.configs[0].index.prefix=loki_index_' \
  --set 'loki.schemaConfig.configs[0].index.period=24h' \
  --set singleBinary.replicas=1 \
  --set singleBinary.persistence.storageClass=longhorn \
  --set read.replicas=0 \
  --set write.replicas=0 \
  --set backend.replicas=0 \
  --wait --timeout 10m
log_ok "Loki ready"

# --- Step 2: Grafana Alloy ---
log_info "Installing Grafana Alloy v${ALLOY_CHART_VERSION} (log-shipping DaemonSet)..."
helm upgrade --install alloy grafana/alloy \
  --version "${ALLOY_CHART_VERSION}" \
  --namespace monitoring \
  --set-file alloy.configMap.content="${MODULE_DIR}/manifests/alloy-config.alloy" \
  --wait --timeout 5m
kubectl rollout status daemonset/alloy -n monitoring --timeout=180s
log_ok "Alloy ready — shipping logs cluster-wide"

# --- Step 3: wire Loki into Grafana ---
log_info "Adding Loki as a Grafana datasource..."
kubectl apply -f "${MODULE_DIR}/manifests/grafana-loki-datasource.yaml"
log_ok "Datasource ConfigMap applied — Grafana's sidecar picks it up within ~1 minute, no restart needed"

echo ""
echo "============================================================"
echo "  Setup complete. Run: bash modules/09-logging/scripts/verify.sh"
echo ""
echo "  Explore logs in Grafana (Explore -> Loki datasource), or query directly:"
echo "  kubectl port-forward -n monitoring svc/loki-gateway 3100:80"
echo "  curl -G -s 'http://localhost:3100/loki/api/v1/query' --data-urlencode 'query={namespace=\"online-boutique\"}' | head"
echo "============================================================"
echo ""
