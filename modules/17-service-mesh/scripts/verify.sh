#!/bin/bash
# =============================================================================
# Module 17 — Service Mesh — verify.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

echo ""
echo "================================================================"
echo "   Module 17 — Service Mesh Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Istio control plane ---${NC}"
ISTIOD_READY=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$ISTIOD_READY" && "$ISTIOD_READY" != "0" ]] && check_pass "istiod is ready" || check_fail "istiod is not ready"

echo ""
echo -e "${BLUE}--- Sidecar injection ---${NC}"
LABEL=$(kubectl get namespace online-boutique -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null)
[[ "$LABEL" == "enabled" ]] && check_pass "online-boutique labeled for injection" || check_fail "online-boutique not labeled for injection"

# Istio 1.30's sidecar is a native Kubernetes sidecar container (an
# initContainer with restartPolicy: Always, KEP-753) — it lives in
# .spec.initContainers, not .spec.containers. Checking only containers
# reported 0/N here every time, live, even though injection was
# genuinely working (confirmed by inspecting a pod directly: istio-init
# is absent, istio-proxy is present in initContainers with
# restartPolicy=Always). Also scoped to Running pods only — a
# completed CronJob pod (cart-housekeeping) or an old canary revision's
# pod mid-scale-down during a Rollout are correctly sidecar-less
# without indicating anything broken.
INJECTED=$(kubectl get pods -n online-boutique -l 'app!=node-exporter' --field-selector status.phase=Running -o jsonpath='{range .items[*]}{.spec.containers[*].name}{" "}{.spec.initContainers[*].name}{"\n"}{end}' 2>/dev/null | grep -c "istio-proxy")
TOTAL_NON_NODE_EXPORTER=$(kubectl get pods -n online-boutique -l 'app!=node-exporter' --field-selector status.phase=Running --no-headers 2>/dev/null | wc -l)
if [[ "$INJECTED" -ge 1 && "$INJECTED" -eq "$TOTAL_NON_NODE_EXPORTER" ]]; then
  check_pass "All ${INJECTED} running non-node-exporter pods have an istio-proxy sidecar"
else
  check_fail "${INJECTED}/${TOTAL_NON_NODE_EXPORTER} running pods have a sidecar — check: kubectl get pods -n online-boutique -o wide"
fi

NODE_EXPORTER_SIDECARS=$(kubectl get pods -n online-boutique -l app=node-exporter -o jsonpath='{range .items[*]}{.spec.containers[*].name}{" "}{.spec.initContainers[*].name}{"\n"}{end}' 2>/dev/null | grep -c "istio-proxy")
[[ "$NODE_EXPORTER_SIDECARS" -eq 0 ]] && check_pass "node-exporter correctly excluded from injection" || check_fail "node-exporter unexpectedly has a sidecar"

echo ""
echo -e "${BLUE}--- mTLS ---${NC}"
kubectl get peerauthentication strict-mtls -n online-boutique -o jsonpath='{.spec.mtls.mode}' 2>/dev/null | grep -q STRICT \
  && check_pass "PeerAuthentication strict-mtls is STRICT" || check_fail "PeerAuthentication not STRICT"

echo ""
echo -e "${BLUE}--- Traffic resilience ---${NC}"
kubectl get virtualservice currencyservice -n online-boutique &>/dev/null \
  && check_pass "VirtualService currencyservice exists" || check_fail "VirtualService currencyservice not found"
kubectl get destinationrule currencyservice -n online-boutique &>/dev/null \
  && check_pass "DestinationRule currencyservice exists" || check_fail "DestinationRule currencyservice not found"

echo ""
echo -e "${BLUE}--- Tempo + tracing ---${NC}"
TEMPO_READY=$(kubectl get statefulset tempo -n monitoring -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$TEMPO_READY" && "$TEMPO_READY" != "0" ]] && check_pass "Tempo is ready" || check_fail "Tempo is not ready"

# kubectl rejects combining a resource name with -l in one call ("name
# cannot be provided when a selector is specified") — found live, this
# check failed with that exact error every time regardless of whether
# the ConfigMap and its label were actually correct (confirmed
# separately they were). Fetch by name, then check the label value.
TEMPO_DS_LABEL=$(kubectl get configmap grafana-tempo-datasource -n monitoring -o jsonpath='{.metadata.labels.grafana_datasource}' 2>/dev/null)
[[ "$TEMPO_DS_LABEL" == "1" ]] \
  && check_pass "Grafana Tempo datasource ConfigMap exists" || check_fail "Grafana Tempo datasource not found"

TRACE_SEARCH=$(kubectl run tempo-verify-$$ --image=curlimages/curl:8.10.1 --restart=Never --rm -q -i --timeout=30s \
  --overrides="{\"spec\":{\"containers\":[{\"name\":\"tempo-verify-$$\",\"image\":\"curlimages/curl:8.10.1\",\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"50m\",\"memory\":\"32Mi\"}}}]}}" -- \
  curl -s --max-time 10 "http://tempo.monitoring.svc:3200/api/search?tags=service.name%3Dfrontend" \
  </dev/null 2>/dev/null)
if echo "$TRACE_SEARCH" | grep -q '"traceID"'; then
  check_pass "Real traces from frontend found in Tempo — application-level tracing is genuinely working"
else
  check_warn "No frontend traces found yet — browse the app (kubectl port-forward svc/frontend) to generate some, or give it a minute"
fi

echo ""
echo -e "${BLUE}--- Kiali ---${NC}"
KIALI_READY=$(kubectl get deployment kiali -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ -n "$KIALI_READY" && "$KIALI_READY" != "0" ]] && check_pass "Kiali is ready" || check_fail "Kiali is not ready"

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 17 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 17 complete!${NC}"
  echo -e "    Next: cat modules/18-chaos-engineering/README.md"
  echo ""
  exit 0
fi
