# shellcheck shell=bash
# What the gate scripts (scripts/gates/*.sh) share; sourced, never run: . "$(dirname "$0")/lib.sh"
#
#   GATES_ROOT                       the repo root, from this file's place (no git needed, worktrees included)
#   GATES_SOURCE                     what SAST and the dependency scan read: $GATES_SOURCE when set (a service
#                                    repository's checkout, for service-image.yml), else GATES_ROOT
#   gate_service_dir <service>       the source folder of a service: services/<service> here, else the sibling clone
#                                    ../<service> (ADR 0009; scripts/clone-all.sh puts it there)
#   gate_report_dir <gate> [dir]     creates and prints the gate's report folder as an absolute path: [dir], else
#                                    $REPORT_DIR, else reports/<gate> under the repo root
#   gate_cache [sub]                 creates and prints the download cache, $GATES_CACHE (default ~/.cache/eshop-gates)
#   gate_copy_defaults               exports the temporary copy's defaults (temporary-copy/defaults.env) that the
#                                    environment doesn't already set
GATES_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GATES_SOURCE=$(cd "${GATES_SOURCE:-$GATES_ROOT}" && pwd)

gate_service_dir() {
  if [ -d "$GATES_ROOT/services/$1" ]; then
    echo "$GATES_ROOT/services/$1"
  elif [ -d "$GATES_ROOT/../$1" ]; then
    (cd "$GATES_ROOT/../$1" && pwd)
  else
    echo "no source for $1: neither services/$1 nor ../$1 (scripts/clone-all.sh clones it there)" >&2
    return 1
  fi
}

gate_report_dir() {
  local dir=${2:-${REPORT_DIR:-$GATES_ROOT/reports/$1}}
  mkdir -p "$dir" && (cd "$dir" && pwd)
}

gate_cache() {
  local dir=${GATES_CACHE:-$HOME/.cache/eshop-gates}${1:+/$1}
  mkdir -p "$dir" && echo "$dir"
}

gate_copy_defaults() {
  local name value
  while IFS='=' read -r name value; do
    [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue # comments and blank lines
    [ -n "${!name:-}" ] || export "$name=$value"
  done <"$GATES_ROOT/scripts/gates/temporary-copy/defaults.env"
}
