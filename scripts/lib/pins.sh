# shellcheck shell=bash
# The environments' pins (clusters/local/*-release.yaml) as they are at a commit, rather than in the working tree;
# sourced by the release and e2e scripts, never run. Needs the commit in this clone.
#
#   pin_at <rev> <env>               prints the version <env> is pinned to at <rev> (scripts/pin-release.sh <env>)
#   pin_at <rev> --suspended <env>   exit 0: <env> is still suspended at <rev> (`# release-pin-until: <env>`), its pin
#                                    a placeholder nothing deploys; 1: not suspended; 2: no pin
# Other exits and messages are pin-release.sh's: non-zero when the pin is missing or unreadable.
pin_at() {
  local rev=$1 dir status=0
  shift
  dir=$(mktemp -d)
  git archive "$rev" clusters/local | tar -x -C "$dir" || { rm -rf "$dir"; return 1; }
  PIN_DIR="$dir/clusters/local" "$(dirname "${BASH_SOURCE[0]}")/../pin-release.sh" "$@" || status=$?
  rm -rf "$dir"
  return "$status"
}
