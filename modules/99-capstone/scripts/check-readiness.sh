#!/bin/bash
# =============================================================================
# Module 99 — Capstone — check-readiness.sh
#
# Installs NOTHING. The Capstone assumes Modules 00-18 are already deployed
# (this is the payoff module for everything built so far, not a from-scratch
# rebuild) — this script just runs every module's own verify.sh in order
# and reports which ones are actually healthy right now.
#
# A module reporting NOT READY here doesn't necessarily block the Capstone
# (e.g. Module 14's second cluster isn't touched by anything in this
# module) — read the summary and judge for yourself which gaps matter for
# the incident you're about to face.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

MODULES=(
  "00-prerequisites"
  "01-cluster-setup"
  "02-core-workloads"
  "03-config-secrets"
  "04-networking-gateway"
  "05-storage"
  "06-security-policy"
  "07-scalability-ha"
  "08-observability"
  "09-logging"
  "10-package-management"
  "11-gitops-cicd"
  "12-progressive-delivery"
  "13-cluster-operations"
  "14-multi-cluster-mgmt"
  "15-multi-tenancy-cost"
  "16-supply-chain-security"
  "17-service-mesh"
  "18-chaos-engineering"
)

echo ""
echo "================================================================"
echo "  Module 99 — Capstone — Readiness Check"
echo "================================================================"
echo ""
echo "Running every module's own verify.sh against the current cluster."
echo "This can take a while (18 modules, several curl/kubectl-run checks each)."
echo ""

READY=0
NOT_READY=0
declare -a NOT_READY_LIST=()

for m in "${MODULES[@]}"; do
  VERIFY="${REPO_ROOT}/modules/${m}/scripts/verify.sh"
  if [[ ! -f "$VERIFY" ]]; then
    echo -e "  ${YELLOW}SKIP${NC}  ${m} (no verify.sh)"
    continue
  fi
  printf "  %-28s" "$m"
  if bash "$VERIFY" &>/tmp/capstone-readiness-${m}.log; then
    echo -e "${GREEN}READY${NC}"
    READY=$((READY+1))
  else
    echo -e "${RED}NOT READY${NC}  (log: /tmp/capstone-readiness-${m}.log)"
    NOT_READY=$((NOT_READY+1))
    NOT_READY_LIST+=("$m")
  fi
done

echo ""
echo "================================================================"
echo -e "  ${GREEN}${READY} ready${NC}  |  ${RED}${NOT_READY} not ready${NC}"
echo "================================================================"

if (( NOT_READY > 0 )); then
  echo ""
  echo "Not ready:"
  for m in "${NOT_READY_LIST[@]}"; do
    echo "  - ${m}  (bash modules/${m}/scripts/verify.sh for details)"
  done
  echo ""
  echo -e "${YELLOW}Fix what's relevant to your incident before proceeding, or accept the gap and note it in your postmortem.${NC}"
fi

echo ""
