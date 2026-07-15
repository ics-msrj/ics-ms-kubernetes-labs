#!/usr/bin/env bash
# =============================================================================
# AKS Platform Track — check-prerequisites.sh (Module 00 equivalent)
#
# Same idea as modules/00-prerequisites/scripts/verify.sh — check everything
# up front, not one failure at a time — with the one real substitution this
# track needs: `az` replaces `ssh` as a required tool (AKS operation never
# SSHes to a node), everything else (kubectl/helm/jq/git) is identical to
# the native track's own requirements.
# =============================================================================
set -uo pipefail

FAIL=0

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

check_version() {
  local name="$1" min="$2" got="$3"
  if [ -z "$got" ]; then
    printf "  %-12s FAIL  (not found)\n" "$name"
    FAIL=1
  elif version_ge "$got" "$min"; then
    printf "  %-12s PASS  (%s, minimum %s)\n" "$name" "$got" "$min"
  else
    printf "  %-12s FAIL  (found %s, need >= %s)\n" "$name" "$got" "$min"
    FAIL=1
  fi
}

check_present() {
  local name="$1" required="$2"
  if command -v "$name" >/dev/null 2>&1; then
    printf "  %-12s PASS  (present)\n" "$name"
  elif [ "$required" = "required" ]; then
    printf "  %-12s FAIL  (not found)\n" "$name"
    FAIL=1
  else
    printf "  %-12s SKIP  (optional, not found)\n" "$name"
  fi
}

echo "== AKS Platform Track — Prerequisites verification =="
echo

echo "Required tools:"
check_version kubectl 1.28.0 "$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"v[0-9.]*"' | head -1 | grep -o '[0-9][0-9.]*')"
check_version helm    3.14.0 "$(helm version --short 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -1 | tr -d v)"
check_version git     2.30.0 "$(git --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
check_version jq      1.6    "$(jq --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
check_present az required
check_present terraform optional

echo
echo "Azure session:"
if az account show -o none 2>/dev/null; then
  ACCOUNT=$(az account show --query name -o tsv 2>/dev/null)
  printf "  %-12s PASS  (logged in: %s)\n" "az login" "${ACCOUNT}"
else
  printf "  %-12s FAIL  (run: az login)\n" "az login"
  FAIL=1
fi

echo
echo "Lab configuration:"
if [ -f "platforms/aks/config/aks.env" ]; then
  printf "  %-12s PASS  (found)\n" "aks.env"
else
  printf "  %-12s FAIL  (run: cp platforms/aks/config/aks.env.example platforms/aks/config/aks.env)\n" "aks.env"
  FAIL=1
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All checks passed. Continue with platforms/aks/README.md's Cluster/Foundation steps."
else
  echo "One or more checks failed. Fix the FAILs above, then re-run this script." >&2
fi
exit "$FAIL"
