#!/usr/bin/env bash
# What the smoke test (.github/workflows/e2e.yml) tests: one line per target, `<environment> <what it must serve>`
# (ADR 0008): a version for qa and prod, a full main commit for dev. Run in a clone of the repository that has the
# commits named and origin/main fetched.
#
#   scripts/smoke-targets.sh push <before> <after>   # a push to main, its before and after commits
#   -> dev 3f2c...                                    #   dev at the pushed commit
#   -> qa 0.3.0-rc.1                                  #   a QA promotion: QA at its new pin, and no dev line
#   scripts/smoke-targets.sh dispatch dev [commit]    # a manual run: main's head, or that main commit
#   scripts/smoke-targets.sh dispatch qa X.Y.Z-rc.N   #   QA's candidate (required: sign-off names the run by it)
#   scripts/smoke-targets.sh dispatch prod [X.Y.Z]    #   prod's pin on main when not given
#
# A push to main means dev at the pushed commit: Flux deploys every main commit to eshop-dev, its own image-update
# commits included. A push that changes a `# release-pin: <env>` line in clusters/local/*.yaml (a promotion or a
# rollback PR) also means that environment at the version pinned in <after> (a line each, so a push moving both
# pins tests both), unless the environment is still suspended (`# release-pin-until: <env>`): its pin is then a
# placeholder and nothing is deployed. A push changing nothing but pin lines has no dev line: dev's deploy is the
# same as before. The lines are the job matrix; e2e.yml waits for each environment to serve its target
# (e2e/check-serving.sh --wait) and records the result as a Deployment (scripts/deployment.sh).
# Exit 1: a commit or pin it can't find; 2: bad arguments. Tests: scripts/tests/release-scripts.sh.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"
# shellcheck source=lib/pins.sh
. "$(dirname "$0")/lib/pins.sh"

usage() {
  [ $# -eq 0 ] || echo "smoke-targets.sh: $*" >&2
  echo "usage: scripts/smoke-targets.sh push <before> <after>   |   scripts/smoke-targets.sh dispatch" \
    "dev [commit] | qa X.Y.Z-rc.N | prod [X.Y.Z]" >&2
  exit 2
}

commit() { # commit <rev>: its full SHA, or fail naming it
  git rev-parse --verify --quiet "$1^{commit}" || { echo "smoke-targets.sh: no commit '$1' here" >&2; exit 1; }
}

case "${1:-} ${2:-}" in
  "push "*)
    [ $# -eq 3 ] || usage
    after=$(commit "$3")
    only_pins=false
    # No <before> here (a new branch's all-zero SHA, a force push's lost commit): dev only, as for any push.
    if before=$(git rev-parse --verify --quiet "$2^{commit}"); then
      # The lines this push changed in the pin files, removed and added, without the diff's own headers.
      changed=$(git diff --unified=0 --no-color "$before" "$after" -- 'clusters/local/*.yaml' \
        | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) ' || true)
      envs=$(sed -nE 's/.* # release-pin: ([a-z]+)$/\1/p' <<<"$changed" | sort -u)
      if [ -n "$envs" ]; then
        for env in $envs; do
          # Exit 0: still suspended (`# release-pin-until: <env>`), its pin a placeholder nothing deploys; 2: no
          # pin left at all. Neither deploys anything to test.
          suspended=0
          pin_at "$after" --suspended "$env" 2>/dev/null || suspended=$?
          [ "$suspended" -eq 1 ] || continue
          version=$(pin_at "$after" "$env") || exit 1
          echo "$env $version"
        done
        # Nothing but pin lines changed (a promotion or rollback PR): dev's deploy is the same, so no dev test.
        if ! git diff --name-only "$before" "$after" | grep -qvE '^clusters/local/[^/]+\.yaml$' \
          && ! grep -qvE ' # release-pin(-until)?: [a-z]+$' <<<"$changed"; then
          only_pins=true
        fi
      fi
    fi
    $only_pins || echo "dev $after"
    ;;
  "dispatch dev")
    [ $# -le 3 ] || usage
    echo "dev $(commit "${3:-origin/main}")"
    ;;
  "dispatch qa" | "dispatch prod")
    [ $# -le 3 ] || usage
    env=$2 version=${3:-}
    if [ -z "$version" ] && [ "$env" = prod ]; then
      # main's pin, whatever branch the workflow was dispatched from.
      version=$(pin_at origin/main prod)
    fi
    env_takes "$env" "$version" || usage "$env takes $(env_grammar "$env"), not '$version'"
    echo "$env $version"
    ;;
  *) usage ;;
esac
