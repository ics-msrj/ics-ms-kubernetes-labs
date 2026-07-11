#!/usr/bin/env bash
# Module 00 — Prerequisites — verify.sh
# Prints PASS/FAIL for every required tool and minimum version.
# Exits non-zero if anything fails, per the module contract.
set -uo pipefail

FAIL=0

# version_ge A B -> true if version A >= version B
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

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

echo "== Module 00 — Prerequisites verification =="
echo

echo "Required tools:"
check_version kubectl   1.28.0 "$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"v[0-9.]*"' | head -1 | grep -o '[0-9][0-9.]*')"
check_version helm      3.14.0 "$(helm version --short 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -1 | tr -d v)"
check_version kustomize 5.0.0  "$(kustomize version 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -1 | tr -d v)"
check_version git       2.30.0 "$(git --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
check_version yq        4.35.0 "$(yq --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
check_version jq        1.6    "$(jq --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)"
check_present ssh required

echo
echo "Recommended (optional):"
check_present k9s optional

echo
echo "Lab configuration:"
if [ -f "lab.env" ]; then
  printf "  %-12s PASS  (found at repo root)\n" "lab.env"
else
  printf "  %-12s FAIL  (run: cp lab.env.example lab.env)\n" "lab.env"
  FAIL=1
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All checks passed. Continue to Module 01 — Cluster Setup."
else
  echo "One or more checks failed. Fix the FAILs above, then re-run this script." >&2
fi
exit "$FAIL"
