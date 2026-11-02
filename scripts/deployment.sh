#!/usr/bin/env bash
# A smoke test's GitHub Deployment (ADR 0008): the record of which version or commit was tested in which environment,
# and how that went. e2e.yml makes one per target (scripts/smoke-targets.sh).
#
#   scripts/deployment.sh start <env> <ref> <log_url> <environment_url>
#       creates the Deployment of <ref> (a tag vX.Y.Z[-rc.N] or a main commit) to <env> (dev, qa or prod), in
#       progress, and prints its id. Only from a run on main: it refuses (exit 1, recording nothing) unless
#       GITHUB_REF is refs/heads/main, and records in the payload which ref ran it and which run attempt
#       ({workflow_ref, run_url, run_id, run_attempt} from GITHUB_REF, <log_url>, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT)
#   scripts/deployment.sh finish <id> success|failure|inactive <log_url> <environment_url> [description]
#       its outcome: success or failure, or inactive when it tested nothing (description `superseded`, `cancelled`,
#       and why). On success the environment's earlier successful Deployments become inactive, `replaced by <ref>`:
#       the environment no longer serves them (a promotion, or a rollback to an earlier release)
#   scripts/deployment.sh sweep <env> <id>
#       marks every other in-progress Deployment of <env> whose run attempt has ended inactive, `abandoned`: that run
#       will never finish it (its runner pod was killed, or its last step failed). Runs still going are left alone:
#       QA and prod runs may overlap (e2e.yml)
#
# Only Deployments recorded on main are read back (scripts/lib/deployments.sh): sign-off and release.sh's dev check
# take nothing else as evidence. Created through the Deployments API rather than a job's `environment:` key, which
# would record the workflow's ref (main) instead of what was tested. auto_merge is off (GitHub would otherwise merge
# main into the ref) and no commit status is required. GitHub's own auto_inactive skips production environments, so
# finish marks the earlier successful ones inactive itself rather than rely on how GitHub classifies qa and prod.
# Needs gh with Deployments write access (GITHUB_TOKEN: `deployments: write`; sweep also `actions: read`).
# Tests: scripts/tests/release-scripts.sh.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"
# shellcheck source=lib/repo.sh
. "$(dirname "$0")/lib/repo.sh"
# shellcheck source=lib/deployments.sh
. "$(dirname "$0")/lib/deployments.sh"

usage() {
  echo "usage: scripts/deployment.sh start <dev|qa|prod> <ref> <log_url> <environment_url>" \
    "| finish <id> <success|failure|inactive> <log_url> <environment_url> [description]" \
    "| sweep <dev|qa|prod> <id>" >&2
  exit 2
}
is_id() { [[ "$1" =~ ^[0-9]+$ ]]; }

# status <id> <state> [log_url] [environment_url] [description]: adds a status (the description cut to GitHub's 140)
status() {
  jq -n --arg state "$2" --arg log "${3:-}" --arg url "${4:-}" --arg d "${5:-}" \
    '{state: $state} + (if $log != "" then {log_url: $log} else {} end)
     + (if $url != "" then {environment_url: $url} else {} end)
     + (if $d != "" then {description: $d[0:140]} else {} end)' \
    | gh api "repos/$REPO/deployments/$1/statuses" --method POST --input - >/dev/null
}

case "${1:-}" in
  start)
    { [ $# -eq 5 ] && is_env "$2"; } || usage
    if [ "${GITHUB_REF:-}" != "$MAIN_REF" ]; then
      echo "deployment.sh: a smoke test records a Deployment only from a run on main (this run: ${GITHUB_REF:-unknown});" \
        "nothing recorded" >&2
      exit 1
    fi
    id=$(jq -n --arg ref "$3" --arg env "$2" --arg wf "$GITHUB_REF" --arg run "$4" \
        --arg run_id "${GITHUB_RUN_ID:-}" --arg attempt "${GITHUB_RUN_ATTEMPT:-}" \
        '{ref: $ref, environment: $env, auto_merge: false, required_contexts: [],
          description: "smoke test of \($ref) on \($env)",
          payload: {workflow_ref: $wf, run_url: $run, run_id: $run_id, run_attempt: $attempt}}' \
      | gh api "repos/$REPO/deployments" --method POST --input - --jq .id)
    status "$id" in_progress "$4" "$5"
    echo "$id"
    ;;
  finish)
    { [[ $# =~ ^[56]$ ]] && is_id "$2" && [[ "$3" =~ ^(success|failure|inactive)$ ]]; } || usage
    status "$2" "$3" "$4" "$5" "${6:-}"
    [ "$3" = success ] || exit 0
    # The environment now serves this ref: its earlier successful Deployments no longer describe it.
    read -r env ref < <(gh api "repos/$REPO/deployments/$2" --jq '"\(.environment) \(.ref)"')
    while read -r id _; do
      { [ -n "$id" ] && [ "$id" -lt "$2" ]; } || continue
      [ "$(latest_status "$id" | jq -r .state)" = success ] || continue
      status "$id" inactive "" "" "replaced by $ref"
    done < <(deployments_of "$env")
    ;;
  sweep)
    { [ $# -eq 3 ] && is_env "$2" && is_id "$3"; } || usage
    while read -r id _; do
      { [ -n "$id" ] && [ "$id" != "$3" ]; } || continue
      [ "$(latest_status "$id" | jq -r .state)" = in_progress ] || continue
      run_ended "$id" || continue
      status "$id" inactive "" "" "abandoned: its run ended without recording an outcome"
      echo "Deployment $id of $2 was in progress, but its run has ended: marked inactive, abandoned" >&2
    done < <(deployments_of "$2")
    ;;
  *) usage ;;
esac
