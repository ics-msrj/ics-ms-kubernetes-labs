#!/bin/bash
# =============================================================================
# Module 09 — Logging — verify.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

# Args go inside --overrides (as the container's "args"), not after a
# trailing "--" — kubectl silently drops a trailing exec command when
# --overrides already defines containers[0], leaving curl to run with no
# arguments at all (prints its own usage text, not a request failure).
loki_get() {
  kubectl run "loki-verify-$$" --image=curlimages/curl:8.10.1 --restart=Never --rm -q -i --timeout=30s \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"loki-verify-$$\",\"image\":\"curlimages/curl:8.10.1\",\"args\":[\"-s\",\"--max-time\",\"10\",\"http://loki-gateway.monitoring.svc.cluster.local$1\"],\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"50m\",\"memory\":\"32Mi\"}}}]}}" \
    </dev/null 2>/dev/null
}

# The gateway's nginx only proxies specific whitelisted paths (see
# loki-gateway's ConfigMap) — /ready isn't one of them and 404s through the
# gateway. It's meant to be probed against the loki Service directly.
loki_get_direct() {
  kubectl run "loki-verify-$$" --image=curlimages/curl:8.10.1 --restart=Never --rm -q -i --timeout=30s \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"loki-verify-$$\",\"image\":\"curlimages/curl:8.10.1\",\"args\":[\"-s\",\"--max-time\",\"10\",\"http://loki.monitoring.svc.cluster.local:3100$1\"],\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"50m\",\"memory\":\"32Mi\"}}}]}}" \
    </dev/null 2>/dev/null
}

echo ""
echo "================================================================"
echo "   Module 09 — Logging Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Loki ---${NC}"
LOKI_READY=$(kubectl get statefulset loki -n monitoring -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$LOKI_READY" && "$LOKI_READY" != "0" ]] && check_pass "Loki StatefulSet is ready" || check_fail "Loki StatefulSet is not ready"

READY_RESP=$(loki_get_direct "/ready")
if [[ "$READY_RESP" == *"ready"* ]]; then
  check_pass "Loki /ready reports ready"
else
  check_fail "Loki /ready did not return 'ready' (got '${READY_RESP:-<none>}')"
fi

PVC_BOUND=$(kubectl get pvc -n monitoring -l app.kubernetes.io/name=loki -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
[[ "$PVC_BOUND" == "Bound" ]] && check_pass "Loki's PVC is Bound (Longhorn)" || check_warn "Could not confirm Loki's PVC is Bound (got '${PVC_BOUND:-<none>}')"

echo ""
echo -e "${BLUE}--- Alloy (log-shipping DaemonSet) ---${NC}"
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
ALLOY_READY=$(kubectl get daemonset alloy -n monitoring -o jsonpath='{.status.numberReady}' 2>/dev/null)
if [[ -n "$ALLOY_READY" && "$ALLOY_READY" == "$NODE_COUNT" ]]; then
  check_pass "Alloy: ${ALLOY_READY}/${NODE_COUNT} nodes"
else
  check_fail "Alloy: ${ALLOY_READY:-0}/${NODE_COUNT} nodes ready"
fi

echo ""
echo -e "${BLUE}--- Logs are actually flowing ---${NC}"
LABELS=$(loki_get "/loki/api/v1/labels")
if echo "$LABELS" | grep -q '"namespace"'; then
  check_pass "Loki has indexed a 'namespace' label from real log streams"
else
  check_warn "Could not confirm the 'namespace' label exists yet — Alloy may still be catching up, give it a minute"
fi

QUERY_RESULT=$(loki_get "/loki/api/v1/query?query=%7Bnamespace%3D%22online-boutique%22%7D&limit=1")
if echo "$QUERY_RESULT" | grep -q '"status":"success"' && echo "$QUERY_RESULT" | grep -q '"stream"'; then
  check_pass "A real log line from online-boutique is queryable in Loki"
else
  check_warn "No online-boutique log lines returned yet — check: kubectl logs -n monitoring daemonset/alloy"
fi

echo ""
echo -e "${BLUE}--- Grafana integration ---${NC}"
# kubectl rejects a specific resource name combined with -l — list by
# selector alone and check the name is in the results.
if kubectl get configmap -n monitoring -l grafana_datasource=1 -o name 2>/dev/null | grep -q '^configmap/grafana-loki-datasource$'; then
  check_pass "Grafana Loki datasource ConfigMap exists and is labeled for sidecar discovery"
else
  check_fail "grafana-loki-datasource ConfigMap missing or not labeled grafana_datasource=1"
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 09 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 09 complete!${NC}"
  echo -e "    Next: cat modules/10-package-management/README.md"
  echo ""
  exit 0
fi
