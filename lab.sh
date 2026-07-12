#!/bin/bash
# =============================================================================
# lab.sh — unified CLI for this repo's modules.
#
# A thin wrapper around what every module's README already tells you to run
# by hand (`bash modules/NN-name/scripts/setup.sh`, etc.) — it does not
# replace reading the README, it just saves typing the path and looking up
# which modules deviate from the standard setup.sh/verify.sh/destroy.sh
# contract (Module 01 has none of the three at top level; Module 99 has
# check-readiness.sh instead of setup.sh/verify.sh; several modules ship
# extra one-off scripts beyond the standard three).
#
# Usage:
#   ./lab.sh list                        list every module, number + name + status
#   ./lab.sh scripts <module>             list a module's actual scripts
#   ./lab.sh setup   <module>             run its setup.sh
#   ./lab.sh verify  <module>             run its verify.sh
#   ./lab.sh destroy <module>             run its destroy.sh
#   ./lab.sh run     <module> <script> [args...]   run any other script by name
#   ./lab.sh status                       run every module's verify.sh, summarize
#                                         and exit non-zero if any are unhealthy
#
# <module> accepts a number (01, 1, 18, 99), a full directory name
# (01-cluster-setup), or a fuzzy substring (cluster-setup, capstone).
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="${REPO_ROOT}/modules"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  # Prints the header comment block (everything between the first and last
  # '# ====...' banner lines) rather than a hardcoded line range, so this
  # can't silently go stale if the header comment above gets edited.
  awk '/^# ====/{n++; next} n==1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Resolves a user-supplied module identifier to a real modules/NN-name
# directory. Tries, in order: exact directory name, zero-padded numeric
# prefix, fuzzy substring match. Prints the resolved path, or nothing (and
# returns 1) if no module matches.
resolve_module() {
  local input="$1"
  if [[ -d "${MODULES_DIR}/${input}" ]]; then
    echo "${MODULES_DIR}/${input}"
    return 0
  fi
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    local padded match
    # Bash printf treats a leading zero as an octal literal. Force decimal so
    # user-facing identifiers such as 08 and 09 resolve to their own modules.
    padded=$(printf '%02d' "$((10#$input))")
    match=$(find "$MODULES_DIR" -maxdepth 1 -type d -name "${padded}-*" | head -1)
    if [[ -n "$match" ]]; then
      echo "$match"
      return 0
    fi
  fi
  local fuzzy
  fuzzy=$(find "$MODULES_DIR" -maxdepth 1 -type d -iname "*${input}*" | head -1)
  if [[ -n "$fuzzy" ]]; then
    echo "$fuzzy"
    return 0
  fi
  return 1
}

cmd_list() {
  echo ""
  echo "================================================================"
  echo "  Modules"
  echo "================================================================"
  echo ""
  grep -E '^\| [0-9]{2} \|' "${REPO_ROOT}/README.md" | \
    sed -E 's/^\| ([0-9]{2}) \| \[([^]]+)\]\([^)]+\) \| ([A-Za-z]+) \| (.) \|.*/\1  \4  \3\t\2/' | \
    column -t -s $'\t'
  echo ""
}

cmd_scripts() {
  local mod_dir
  mod_dir=$(resolve_module "$1") || { log_error "No module matches '$1'. Try: ./lab.sh list"; exit 1; }
  echo "${mod_dir##*/}:"
  find "${mod_dir}/scripts" -maxdepth 1 -type f -name '*.sh' -printf '  %f\n' 2>/dev/null | sort
}

run_standard_script() {
  local action="$1" module="$2"
  local mod_dir
  mod_dir=$(resolve_module "$module") || { log_error "No module matches '$module'. Try: ./lab.sh list"; exit 1; }
  local script="${mod_dir}/scripts/${action}.sh"

  if [[ -f "$script" ]]; then
    log_info "Running ${script##"${REPO_ROOT}/"}..."
    bash "$script"
    return $?
  fi

  # Known deviations from the standard contract — point at what actually
  # exists instead of just failing.
  local name
  name="${mod_dir##*/}"
  case "${name}:${action}" in
    01-cluster-setup:setup)
      log_warn "Module 01 has no single setup.sh — bootstrapping a real VM cluster"
      log_warn "is a guided manual walkthrough (scp + ssh onto each VM). See:"
      echo "    modules/01-cluster-setup/README.md"
      exit 1
      ;;
    99-capstone:setup)
      log_warn "Module 99 has no setup.sh by design — it assumes Modules 00-18 are"
      log_warn "already deployed. Use: ./lab.sh verify 99 (runs check-readiness.sh)"
      exit 1
      ;;
    99-capstone:verify)
      log_info "Module 99 uses check-readiness.sh instead of verify.sh — running that."
      bash "${mod_dir}/scripts/check-readiness.sh"
      return $?
      ;;
    *)
      log_error "${script##"${REPO_ROOT}/"} not found."
      log_info "Available scripts in this module:"
      cmd_scripts "$module"
      exit 1
      ;;
  esac
}

cmd_run() {
  local module="$1" script_name="$2"
  shift 2
  local mod_dir
  mod_dir=$(resolve_module "$module") || { log_error "No module matches '$module'. Try: ./lab.sh list"; exit 1; }
  local script="${mod_dir}/scripts/${script_name}"
  [[ "$script" == *.sh ]] || script="${script}.sh"
  if [[ ! -f "$script" ]]; then
    log_error "${script##"${REPO_ROOT}/"} not found."
    cmd_scripts "$module"
    exit 1
  fi
  log_info "Running ${script##"${REPO_ROOT}/"} $*..."
  bash "$script" "$@"
}

cmd_status() {
  local readiness="${MODULES_DIR}/99-capstone/scripts/check-readiness.sh"
  if [[ ! -f "$readiness" ]]; then
    log_error "modules/99-capstone/scripts/check-readiness.sh not found."
    exit 1
  fi
  bash "$readiness"
}

ACTION="${1:-}"
case "$ACTION" in
  list)
    cmd_list
    ;;
  scripts)
    [[ -n "${2:-}" ]] || { log_error "Usage: ./lab.sh scripts <module>"; exit 1; }
    cmd_scripts "$2"
    ;;
  setup|verify|destroy)
    [[ -n "${2:-}" ]] || { log_error "Usage: ./lab.sh ${ACTION} <module>"; exit 1; }
    run_standard_script "$ACTION" "$2"
    ;;
  run)
    [[ -n "${2:-}" && -n "${3:-}" ]] || { log_error "Usage: ./lab.sh run <module> <script> [args...]"; exit 1; }
    cmd_run "${@:2}"
    ;;
  status)
    cmd_status
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    log_error "Unknown command: ${ACTION}"
    usage
    exit 1
    ;;
esac
