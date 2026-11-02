#!/usr/bin/env bash
# How a smoke test of one target ended (ADR 0008; e2e.yml's test job), decided once for the Deployment's outcome
# (scripts/deployment.sh) and the email (scripts/notify.sh). Run in a clone with origin/main fetched.
#
#   scripts/smoke-result.sh current <env> <target>
#       exit 0: <target> is still what <env> should serve, by origin/main; 1: it isn't, and says why on stdout, e.g.
#       `eshop-qa is pinned to 0.3.0-rc.2 on main now, not 0.3.0-rc.1`. Dev is always current: a newer dev run
#       cancels an older one instead (e2e.yml's concurrency)
#   scripts/smoke-result.sh of <env> <target> <job status> <wait outcome> [retried file]
#       prints the result, one of
#         passed, retried     the job succeeded (retried: a test passed only on its retry, listed in [retried file])
#         not-deployed        it failed waiting for the environment to serve the target (<wait outcome> failure)
#         failed              it failed otherwise: the test, or the environment changed during it
#         superseded <why>    QA or prod: it failed or was cancelled, and the target is no longer the environment's
#                             pin on main (a newer promotion or a rollback merged meanwhile): it tested nothing that
#                             still matters. Dev: cancelled by a newer dev run
#         cancelled           QA or prod, still the pin: cancelled by hand
#       <job status> is the job's (success, failure or cancelled), <wait outcome> the wait step's.
#
# Why QA and prod need `superseded`: their runs are never cancelled for a newer one (every promotion's run must report
# its target), so two can overlap. The older one then waits for, or tests, a version Flux is replacing, and fails
# (not deployed, or redeployed during the test); that failure says nothing about its version. A pass stands even
# if the pin moved since: the environment served the target before and after the test (e2e/check-serving.sh).
# Exit 2: bad arguments; 3: the pin on main is missing or unreadable (current; `of` then keeps the run's own result).
# Tests: scripts/tests/release-scripts.sh.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"
# shellcheck source=lib/pins.sh
. "$(dirname "$0")/lib/pins.sh"

usage() {
  echo "usage: scripts/smoke-result.sh current <env> <target>" \
    "| of <env> <target> <success|failure|cancelled> <wait outcome> [retried file]" >&2
  echo "  <env> <target>: dev <main commit> | qa X.Y.Z-rc.N | prod X.Y.Z" >&2
  exit 2
}

# current <env> <target>: as above, the reason on stdout
current() {
  [ "$1" != dev ] || return 0
  local suspended=0 pinned
  pin_at origin/main --suspended "$1" 2>/dev/null || suspended=$?
  case "$suspended" in
    0) echo "apps-$1 is suspended on main now: eshop-$1 runs no release"; return 1 ;;
    1) ;;
    *) echo "eshop-$1 has no pin on main" >&2; exit 3 ;;
  esac
  pinned=$(pin_at origin/main "$1") || exit 3
  [ "$pinned" != "$2" ] || return 0
  echo "eshop-$1 is pinned to $pinned on main now, not $2"
  return 1
}

case "${1:-}" in
  current)
    { [ $# -eq 3 ] && is_target "$2" "$3"; } || usage
    current "$2" "$3"
    ;;
  of)
    { [[ $# =~ ^[56]$ ]] && is_target "$2" "$3" && [[ "$4" =~ ^(success|failure|cancelled)$ ]]; } || usage
    env=$2 target=$3 job=$4 waited=$5 retried=${6:-}
    if [ "$job" = success ]; then
      if [ -n "$retried" ] && [ -s "$retried" ]; then echo retried; else echo passed; fi
      exit 0
    fi
    if [ "$env" = dev ]; then
      if [ "$job" = cancelled ]; then echo superseded; exit 0; fi
    else
      # Unreadable (3): the run's own outcome stands, rather than hiding a failure as superseded.
      status=0
      why=$(current "$env" "$target") || status=$?
      if [ "$status" -eq 1 ]; then echo "superseded $why"; exit 0; fi
    fi
    case "$job" in
      cancelled) echo cancelled ;;
      *) if [ "$waited" = failure ]; then echo not-deployed; else echo failed; fi ;;
    esac
    ;;
  *) usage ;;
esac
