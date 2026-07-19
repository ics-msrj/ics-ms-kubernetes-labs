#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — verify.sh
#
# One aggregate check across the whole Foundation flow (check-prerequisites
# through enable-backup) — the individual enable-*.sh scripts don't have
# their own verify.sh the way native modules do, so this is where all of
# them get checked together. Same PASS/FAIL/WARN style as every native
# module's verify.sh. Service mesh (enable-servicemesh.sh) and
# multi-cluster (enable-multicluster.sh/promote-canary.sh) are optional —
# checked only if they look like they were actually run.
# =============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

APP_DOMAIN="${APP_DOMAIN:-}"
GRAFANA_DOMAIN="grafana.${APP_DOMAIN}"

PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   AKS Platform Track — Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Cluster ---${NC}"
if kubectl cluster-info >/dev/null 2>&1; then
  check_pass "kubectl reaches the cluster"
else
  check_fail "kubectl cannot reach the cluster — run connect.sh"
fi
kubectl get nodes -l "${AKS_WORKLOAD_LABEL_KEY}=${AKS_WORKLOAD_LABEL_VALUE}" --no-headers 2>/dev/null | grep -q . \
  && check_pass "Workload node pool has at least one registered node" \
  || check_fail "No node has ${AKS_WORKLOAD_LABEL_KEY}=${AKS_WORKLOAD_LABEL_VALUE}"

echo ""
echo -e "${BLUE}--- Core Workloads (Module 02) ---${NC}"
for dep in frontend cartservice checkoutservice currencyservice emailservice paymentservice \
           productcatalogservice recommendationservice shippingservice adservice loadgenerator; do
  READY=$(kubectl get deployment "$dep" -n online-boutique -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ -n "$READY" && "$READY" != "0" ]] && check_pass "${dep}: ${READY} ready" || check_fail "${dep}: not ready"
done
SC=$(kubectl get pvc redis-data-redis-cart-0 -n online-boutique -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
[[ "$SC" == "${AKS_STORAGE_CLASS}" ]] && check_pass "redis-cart PVC on ${AKS_STORAGE_CLASS}" || check_fail "redis-cart PVC on '${SC:-none}', expected ${AKS_STORAGE_CLASS}"
kubectl get secret redis-cart-credentials -n online-boutique >/dev/null 2>&1 \
  && check_pass "redis-cart-credentials Secret exists" || check_fail "redis-cart-credentials Secret not found"

echo ""
echo -e "${BLUE}--- Networking (Module 04) ---${NC}"
GW_PROGRAMMED=$(kubectl get gateway frontend-gateway -n online-boutique -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
[[ "$GW_PROGRAMMED" == "True" ]] && check_pass "Gateway frontend-gateway is Programmed" || check_fail "Gateway not Programmed"
CERT_READY=$(kubectl get certificate frontend-tls -n online-boutique -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[[ "$CERT_READY" == "True" ]] && check_pass "frontend-tls certificate is Ready" || check_warn "frontend-tls certificate not Ready yet"

echo ""
echo -e "${BLUE}--- Storage (Module 05) ---${NC}"
kubectl get volumesnapshotclass managed-csi >/dev/null 2>&1 \
  && check_pass "VolumeSnapshotClass managed-csi exists" || check_fail "VolumeSnapshotClass managed-csi missing"
SNAP_READY=$(kubectl get volumesnapshot redis-cart-snapshot -n online-boutique -o jsonpath='{.status.readyToUse}' 2>/dev/null)
[[ "$SNAP_READY" == "true" ]] && check_pass "redis-cart-snapshot is ready" || check_warn "redis-cart-snapshot not ready (or not taken yet)"

echo ""
echo -e "${BLUE}--- Scaling (Module 07) ---${NC}"
kubectl get hpa frontend -n online-boutique >/dev/null 2>&1 && check_pass "HPA frontend exists" || check_fail "HPA frontend missing"
kubectl get vpa productcatalogservice -n online-boutique >/dev/null 2>&1 && check_pass "VPA productcatalogservice exists" || check_fail "VPA productcatalogservice missing"
kubectl get pdb cartservice -n online-boutique >/dev/null 2>&1 && check_pass "PDB cartservice exists" || check_fail "PDB cartservice missing"

echo ""
echo -e "${BLUE}--- Observability (Module 08) ---${NC}"
PROM_READY=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[[ "$PROM_READY" -ge 1 ]] && check_pass "Prometheus is Running" || check_fail "Prometheus is not Running"
NODE_EXP_READY=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[[ "$NODE_EXP_READY" -ge 1 ]] && check_pass "kube-prometheus-stack's node-exporter is Running (nodeExporter.enabled=true)" || check_fail "node-exporter not Running — check nodeExporter.enabled"
if [[ -n "$APP_DOMAIN" ]]; then
  GRAFANA_CERT_READY=$(kubectl get certificate grafana-tls -n online-boutique -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "$GRAFANA_CERT_READY" == "True" ]] && check_pass "grafana-tls certificate is Ready" || check_warn "grafana-tls certificate not Ready yet"
fi

echo ""
echo -e "${BLUE}--- Backup (Module 13) ---${NC}"
if [[ "${AKS_ENABLE_AKS_BACKUP:-0}" == "1" ]]; then
  EXT_READY=$(kubectl get pods -n dataprotection-microsoft --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  [[ "$EXT_READY" -ge 1 ]] && check_pass "Azure Backup for AKS extension is Running" || check_fail "dataprotection-microsoft extension not Running"
  if [[ -n "${AKS_BACKUP_RESOURCE_GROUP:-}" && -n "${AKS_BACKUP_VAULT_NAME:-}" ]]; then
    LATEST_STATUS=$(az dataprotection job list --subscription "${AKS_SUBSCRIPTION_ID}" --resource-group "${AKS_BACKUP_RESOURCE_GROUP}" --vault-name "${AKS_BACKUP_VAULT_NAME}" --query "max_by([?properties.operation=='Backup'].properties, &startTime).status" -o tsv 2>/dev/null)
    case "$LATEST_STATUS" in
      Completed) check_pass "Latest AKS Backup job Completed" ;;
      CompletedWithWarnings) check_warn "Latest AKS Backup job Completed With Warnings" ;;
      *) check_warn "Latest AKS Backup job status '${LATEST_STATUS:-<none>}' (run enable-backup.sh)" ;;
    esac
  fi
else
  BSL_PHASE=$(kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$BSL_PHASE" == "Available" ]] && check_pass "Velero BackupStorageLocation is Available" || check_warn "BackupStorageLocation phase '${BSL_PHASE:-<none>}' (run enable-backup.sh)"
  BACKUP_PHASE=$(kubectl get backup online-boutique-backup -n velero -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$BACKUP_PHASE" == "Completed" ]] && check_pass "online-boutique-backup Completed" || check_warn "online-boutique-backup phase '${BACKUP_PHASE:-<none>}'"
fi

echo ""
echo -e "${BLUE}--- Service Mesh (Module 17, optional) ---${NC}"
if kubectl get namespace istio-system >/dev/null 2>&1; then
  MTLS_MODE=$(kubectl get peerauthentication strict-mtls -n online-boutique -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
  [[ "$MTLS_MODE" == "STRICT" ]] && check_pass "mTLS STRICT enforced" || check_fail "mTLS not STRICT"
  KIALI_READY=$(kubectl get deployment kiali -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ -n "$KIALI_READY" && "$KIALI_READY" != "0" ]] && check_pass "Kiali is ready" || check_warn "Kiali not ready"
else
  check_warn "istio-system not found — enable-servicemesh.sh not run (optional)"
fi

echo ""
echo -e "${BLUE}--- Multi-Cluster (Module 14, optional) ---${NC}"
if kubectl get namespace cattle-system >/dev/null 2>&1; then
  RANCHER_READY=$(kubectl get deployment rancher -n cattle-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ -n "$RANCHER_READY" && "$RANCHER_READY" != "0" ]] && check_pass "Rancher is ready" || check_warn "Rancher not ready"
else
  check_warn "cattle-system not found — enable-multicluster.sh not run (optional)"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  AKS platform track NOT fully ready. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  AKS platform track core Foundation is healthy.${NC}"
  echo ""
  exit 0
fi
