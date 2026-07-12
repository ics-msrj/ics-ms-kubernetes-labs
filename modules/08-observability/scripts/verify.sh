#!/bin/bash
# =============================================================================
# Module 08 — Observability — verify.sh
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/lab.env" ] && source "${REPO_ROOT}/lab.env"
APP_DOMAIN="${APP_DOMAIN:-}"
GRAFANA_DOMAIN="grafana.${APP_DOMAIN}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN+1)); }

prom_query() {
  kubectl run prom-verify-$$ --image=curlimages/curl:8.10.1 --restart=Never --rm -q -i --timeout=30s \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"prom-verify-$$\",\"image\":\"curlimages/curl:8.10.1\",\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"50m\",\"memory\":\"32Mi\"}}}]}}" -- \
    curl -s --max-time 10 "http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090/api/v1/$1" \
    </dev/null 2>/dev/null
}

echo ""
echo "================================================================"
echo "   Module 08 — Observability Verification"
echo "================================================================"
echo ""

echo -e "${BLUE}--- Core components ---${NC}"
for dep in monitoring-grafana monitoring-kube-prometheus-operator monitoring-kube-state-metrics; do
  READY=$(kubectl get deployment "$dep" -n monitoring -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ -n "$READY" && "$READY" != "0" ]] && check_pass "$dep is ready" || check_fail "$dep is not ready"
done
PROM_UP=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
AM_UP=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[[ "$PROM_UP" -ge 1 ]] && check_pass "Prometheus pod is Running" || check_fail "Prometheus pod is not Running"
[[ "$AM_UP" -ge 1 ]] && check_pass "Alertmanager pod is Running" || check_fail "Alertmanager pod is not Running"

echo ""
echo -e "${BLUE}--- kube-scheduler / kube-controller-manager scraping ---${NC}"
for job in kube-scheduler kube-controller-manager; do
  TARGET_UP=$(prom_query "query?query=up{job=\"${job}\"}" | grep -o '"value":\[[^]]*\]' | grep -c '"1"')
  if [[ "${TARGET_UP:-0}" -ge 1 ]]; then
    check_pass "${job} target is UP"
  else
    check_warn "${job} target not confirmed UP — likely still bound to 127.0.0.1 (see README Troubleshooting for the --bind-address fix)"
  fi
done

echo ""
echo -e "${BLUE}--- node-exporter reuse (Module 02) ---${NC}"
if kubectl get podmonitor node-exporter -n online-boutique &>/dev/null; then
  check_pass "PodMonitor node-exporter exists"
else
  check_fail "PodMonitor node-exporter not found"
fi
NE_TARGETS=$(prom_query "query?query=up{namespace=\"online-boutique\",pod=~\"node-exporter.*\"}" | grep -o '"value":\[[^]]*\]' | grep -c '"1"')
if [[ "${NE_TARGETS:-0}" -ge 1 ]]; then
  check_pass "Prometheus is successfully scraping ${NE_TARGETS} node-exporter target(s)"
else
  check_warn "Could not confirm node-exporter targets are up via the Prometheus API — check: kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090, then open /targets"
fi

echo ""
echo -e "${BLUE}--- PrometheusRule ---${NC}"
if kubectl get prometheusrule online-boutique-alerts -n online-boutique &>/dev/null; then
  check_pass "PrometheusRule online-boutique-alerts exists"
else
  check_fail "PrometheusRule online-boutique-alerts not found"
fi
RULES_LOADED=$(prom_query "rules" | grep -c "online-boutique.rules")
if [[ "${RULES_LOADED:-0}" -ge 1 ]]; then
  check_pass "Prometheus has loaded the online-boutique.rules group"
else
  check_warn "Could not confirm the rule group loaded via the Prometheus API yet — it can take a minute after apply"
fi

echo ""
echo -e "${BLUE}--- Grafana exposed via Gateway ---${NC}"
CERT_READY=$(kubectl get certificate grafana-tls -n online-boutique -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[[ "$CERT_READY" == "True" ]] && check_pass "Certificate grafana-tls is Ready" || check_fail "Certificate grafana-tls not Ready (got '${CERT_READY:-<none>}')"

ROUTE_ACCEPTED=$(kubectl get httproute grafana -n monitoring -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[[ "$ROUTE_ACCEPTED" == "True" ]] && check_pass "HTTPRoute grafana is Accepted" || check_fail "HTTPRoute grafana not Accepted (got '${ROUTE_ACCEPTED:-<none>}')"

if [[ -n "$APP_DOMAIN" ]]; then
  HEALTH=$(kubectl run grafana-health-$$ --image=curlimages/curl:8.10.1 --restart=Never --rm -q -i --timeout=30s \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"grafana-health-$$\",\"image\":\"curlimages/curl:8.10.1\",\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"cpu\":\"50m\",\"memory\":\"32Mi\"}}}]}}" -- \
    curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "https://${GRAFANA_DOMAIN}/api/health" \
    </dev/null 2>/dev/null)
  if [[ "$HEALTH" == "200" ]]; then
    check_pass "https://${GRAFANA_DOMAIN}/api/health returns 200"
  else
    check_warn "Could not reach https://${GRAFANA_DOMAIN}/api/health from inside the cluster (got '${HEALTH:-<none>}') — DNS propagation or an external firewall can cause this even when everything above is healthy"
  fi
fi

echo ""
echo "================================================================"
echo -e "   Results: ${GREEN}${PASS} passed${NC}  |  ${RED}${FAIL} failed${NC}  |  ${YELLOW}${WARN} warnings${NC}"
echo "================================================================"

if (( FAIL > 0 )); then
  echo ""
  echo -e "${RED}  Module 08 NOT complete. Fix the FAIL items above.${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "${GREEN}  Module 08 complete! Grafana: https://${GRAFANA_DOMAIN}${NC}"
  echo -e "    Next: cat modules/09-logging/README.md"
  echo ""
  exit 0
fi
