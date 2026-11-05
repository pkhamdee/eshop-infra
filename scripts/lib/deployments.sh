# shellcheck shell=bash
# The smoke test's GitHub Deployments (ADR 0008; recorded by scripts/deployment.sh) as the scripts read them, one way
# for deployment.sh, notify.sh, release.sh's dev check and lib/qa.sh's sign-off evidence. Sourced after lib/repo.sh,
# never run; reads with gh_read.
#
# Only a Deployment recorded by a run on main counts: its payload's workflow_ref is refs/heads/main. deployment.sh
# refuses to record one from any other ref, and these readers skip any that says otherwise (or nothing), so a copy of
# e2e.yml run from another branch can never stand as evidence.
#
#   deployments_of <env> [ref=<ref> | sha=<sha>]
#       the newest 30 Deployments of <env> recorded on main (optionally only those of a ref, or of a commit), newest
#       first, a line each: `<id> <ref> <created_at>`. 30 are plenty: each is one smoke test
#   latest_status <id>
#       its latest status as JSON {state, description, log_url}: state `pending` when it has none
#   outcome_of <id>
#       `failure` or `success` from any of its statuses (one marked inactive afterwards, `replaced by`, had succeeded
#       first), nothing when it has neither (superseded or cancelled: it tested nothing)
#   run_ended <id>
#       exit 0 when the workflow run attempt that recorded it (payload run_id, run_attempt) has completed, or is
#       unknown; 1 while it is still queued or running
MAIN_REF=refs/heads/main

deployments_of() {
  gh_read api "repos/$REPO/deployments?environment=$1${2:+&$2}&per_page=30" \
    --jq ".[] | select(.payload.workflow_ref? == \"$MAIN_REF\") | \"\(.id) \(.ref) \(.created_at)\""
}

latest_status() {
  gh_read api "repos/$REPO/deployments/$1/statuses?per_page=1" \
    --jq '(.[0] // {}) | {state: (.state // "pending"), description: (.description // ""), log_url: (.log_url // "")}'
}

outcome_of() {
  gh_read api "repos/$REPO/deployments/$1/statuses?per_page=100" \
    --jq 'map(.state) | if index("failure") then "failure" elif index("success") then "success" else "" end'
}

run_ended() {
  local run attempt
  run=$(gh_read api "repos/$REPO/deployments/$1" --jq '"\(.payload.run_id? // "") \(.payload.run_attempt? // "")"')
  read -r run attempt <<<"$run"
  [ -n "$run" ] && [ -n "$attempt" ] || return 0
  [ "$(gh_read api "repos/$REPO/actions/runs/$run/attempts/$attempt" --jq .status)" = completed ]
}
