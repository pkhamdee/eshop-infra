# shellcheck shell=bash
# QA's evidence for sign-off (docs/git-workflow.md, "Sign-off"), read from origin/main and GitHub's Deployments, one
# way for scripts/sign-off-pr.sh (which opens the sign-off PR) and scripts/sign-off.sh (which re-checks at merge).
# Sourced after lib/repo.sh, in a clone with origin/main fetched; never run. Sources lib/pins.sh and
# lib/deployments.sh: only Deployments recorded by a run on main count.
#
#   qa_pin                      prints the candidate origin/main pins eshop-qa to. Exit 1: its pin is unreadable;
#                               3: apps-qa is suspended (QA runs no candidate yet)
#   qa_pinned_at                prints when origin/main last changed a `# release-pin: qa` line, UTC (on main's
#                               first-parent line, so a promotion PR counts from its merge); empty when never
#   qa_deployment <candidate> <since>
#                               prints QA's latest Deployment of tag v<candidate> created at or after <since>, as
#                               `{id, created_at, state, description, log_url}` (its latest status); nothing when
#                               there is none. An older one tested an earlier deployment (rc.1 -> rc.2 -> rc.1)
# shellcheck source=pins.sh
. "$(dirname "${BASH_SOURCE[0]}")/pins.sh"
# shellcheck source=deployments.sh
. "$(dirname "${BASH_SOURCE[0]}")/deployments.sh"

qa_pin() {
  local suspended=0
  pin_at origin/main --suspended qa 2>/dev/null || suspended=$?
  case "$suspended" in
    0) return 3 ;;
    1) pin_at origin/main qa 2>/dev/null || return 1 ;;
    *) return 1 ;;
  esac
}

qa_pinned_at() {
  TZ=UTC git log -1 --first-parent -m -G '# release-pin(-until)?: qa$' \
    --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd origin/main -- clusters/local
}

qa_deployment() {
  local found id created
  found=$(deployments_of qa "ref=v$1") || return 1
  # Newest first: the first created at or after <since>. ISO 8601 UTC times compare as strings.
  while read -r id _ created; do
    [ -n "$id" ] || continue
    [[ ! "$created" < "$2" ]] || continue
    latest_status "$id" | jq -c --argjson id "$id" --arg created "$created" '{id: $id, created_at: $created} + .'
    return
  done <<<"$found"
}
