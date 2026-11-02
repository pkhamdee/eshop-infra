#!/usr/bin/env bash
# Protects main, the release tags and the release secrets on GitHub, as code (docs/git-workflow.md, "Protecting
# main"; ADR 0007). Idempotent: run it again after changing it, or to put the settings back after an emergency.
#
#   scripts/protect-main.sh --dry-run        # prints every request it would send (reads only); run this first
#   scripts/protect-main.sh                  # applies them
#   scripts/protect-main.sh --approvals 2    # the switch to two required approvals, once there are two approvers
#
# 1. Branch ruleset "Protect main" (created, or updated in place by name):
#    - changes reach main only through a pull request (no direct push, no force-push, no deletion);
#    - the PR's required status checks are every job ci-release.yml runs on a pull request: the jobs with no
#      `needs:` and no `if:`, by their `name:` (the check's context), from GitHub Actions only. The gate, scan and
#      push jobs never run on a PR, so they can't be required; renaming a PR job changes its check, so run this again;
#    - approvals: 0 by default (with one maintainer the merge is the approval: GitHub doesn't let an author approve
#      their own PR). With --approvals N > 0 it also dismisses stale approvals on a new push and requires the last
#      push to be approved by someone other than its pusher;
#    - bypass: deploy keys only, so Flux's image automation (it pushes with the flux-system deploy key) still commits
#      dev's image updates straight to main. Nobody else bypasses, admins included; an emergency is in the docs.
# 2. Tag rulesets on refs/tags/v* (release candidates and releases), each created or updated in place by name:
#    - "Protect release tags": no v* tag is ever deleted, moved or force-pushed, by anyone (no bypass). QA and prod
#      are pinned to a tag, so a moved tag would change what Flux deploys without a promotion PR;
#    - "Create release tags": only repository admins and maintainers create v* tags (rule `creation`, bypassed by
#      the repository roles admin and maintain). A pushed v* tag runs CI in environment `release`, so anyone else
#      could reach its secrets by pushing a tag. scripts/release.sh (a maintainer) and sign-off (PROMOTION_TOKEN, a
#      maintainer's token) create them. A ruleset of its own because a bypass actor bypasses every rule of its
#      ruleset: in "Protect release tags" it would also let maintainers move and delete tags.
# 3. Environment "release", deployable only from main and from v* tags. ci-release.yml's push and promote-qa jobs and
#    sign-off.yml use it, so its secrets (DOCKERHUB_TOKEN, PROMOTION_TOKEN) are out of reach of a workflow run from
#    any other branch. The secrets themselves are a human step (docs/setup.md, "Release secrets").
# 4. Environment "smoke-test", deployable only from main. e2e.yml's notify job uses it (recording no deployment) for
#    SMTP_PASSWORD, to email the smoke test's results; a run from any other branch can't read it. The secret and the
#    repository variables SMTP_USERNAME and NOTIFY_EMAIL are a human step (docs/setup.md, "Smoke test email").
#
# Needs gh signed in as a repo admin, and jq. scripts/tests/release-scripts.sh tests it against a fake gh.
set -euo pipefail

RULESET="Protect main"
TAG_RULESET="Protect release tags"
TAG_CREATION_RULESET="Create release tags"
# Repository role ids in bypass_actors (actor_type RepositoryRole): 2 maintain, 4 write, 5 admin.
ROLE_MAINTAIN=2
ROLE_ADMIN=5
ENVIRONMENT=release
SMOKE_TEST_ENVIRONMENT=smoke-test
GITHUB_ACTIONS_APP_ID=15368 # required checks must come from GitHub Actions, not from any status a token can post

usage() { echo "usage: scripts/protect-main.sh [--dry-run] [--approvals N]   (N from 0 to 10; default 0)" >&2; exit 2; }
dry_run=false
approvals=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --approvals) [ $# -ge 2 ] || usage; approvals=$2; shift ;;
    *) usage ;;
  esac
  shift
done
[[ "$approvals" =~ ^([0-9]|10)$ ]] || usage

cd "$(dirname "$0")/.."
# shellcheck source=lib/repo.sh
. scripts/lib/repo.sh

# The checks: jobs of ci-release.yml with neither `needs:` nor `if:` run on every pull request.
checks=$(awk '
  function flush() { if (id != "" && !gated) print (name != "" ? name : id) }
  /^jobs:/ { in_jobs = 1; next }
  in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); id = $1; sub(/:$/, "", id); name = ""; gated = 0; next }
  in_jobs && /^    name:/ { name = $0; sub(/^    name:[[:space:]]*/, "", name); gsub(/^"|"$/, "", name) }
  in_jobs && /^    (needs|if):/ { gated = 1 }
  END { flush() }
' .github/workflows/ci-release.yml)
if [ -z "$checks" ] || [[ "$checks" == *"\${{"* ]]; then
  echo "can't read the pull-request jobs of .github/workflows/ci-release.yml:" >&2; echo "$checks" >&2; exit 1
fi

if [ "$approvals" -gt 0 ]; then strict_reviews=true; else strict_reviews=false; fi
ruleset=$(jq -n --arg name "$RULESET" --argjson approvals "$approvals" --argjson strict "$strict_reviews" \
  --argjson app "$GITHUB_ACTIONS_APP_ID" --arg checks "$checks" '{
  name: $name,
  target: "branch",
  enforcement: "active",
  conditions: { ref_name: { include: ["refs/heads/main"], exclude: [] } },
  bypass_actors: [ { actor_id: null, actor_type: "DeployKey", bypass_mode: "always" } ],
  rules: [
    { type: "deletion" },
    { type: "non_fast_forward" },
    { type: "pull_request", parameters: {
        required_approving_review_count: $approvals,
        dismiss_stale_reviews_on_push: $strict,
        require_last_push_approval: $strict,
        require_code_owner_review: false,
        required_review_thread_resolution: false } },
    { type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false,
        required_status_checks: [ $checks | split("\n")[] | { context: ., integration_id: $app } ] } }
  ] }')

tag_ruleset=$(jq -n --arg name "$TAG_RULESET" '{
  name: $name,
  target: "tag",
  enforcement: "active",
  conditions: { ref_name: { include: ["refs/tags/v*"], exclude: [] } },
  bypass_actors: [],
  rules: [ { type: "deletion" }, { type: "update" }, { type: "non_fast_forward" } ] }')

tag_creation_ruleset=$(jq -n --arg name "$TAG_CREATION_RULESET" --argjson admin "$ROLE_ADMIN" \
  --argjson maintain "$ROLE_MAINTAIN" '{
  name: $name,
  target: "tag",
  enforcement: "active",
  conditions: { ref_name: { include: ["refs/tags/v*"], exclude: [] } },
  bypass_actors: [
    { actor_id: $admin, actor_type: "RepositoryRole", bypass_mode: "always" },
    { actor_id: $maintain, actor_type: "RepositoryRole", bypass_mode: "always" } ],
  rules: [ { type: "creation" } ] }')

# send <METHOD> <path> [json]: prints it on --dry-run, sends it otherwise.
send() {
  if $dry_run; then
    echo "$1 $2"
    [ -z "${3:-}" ] || jq . <<<"$3"
  elif [ -n "${3:-}" ]; then
    gh api "$2" --method "$1" --input - <<<"$3" >/dev/null && echo "$1 $2: done"
  else
    gh api "$2" --method "$1" >/dev/null && echo "$1 $2: done"
  fi
}

# 1. and 2. The rulesets, each found by name: updated in place, or created.
existing_rulesets=$(gh api "repos/$REPO/rulesets")
upsert_ruleset() { # upsert_ruleset <ruleset json>
  local id
  id=$(jq -r --arg name "$(jq -r .name <<<"$1")" 'map(select(.name == $name)) | first | .id // empty' \
    <<<"$existing_rulesets")
  if [ -n "$id" ]; then send PUT "repos/$REPO/rulesets/$id" "$1"; else send POST "repos/$REPO/rulesets" "$1"; fi
}
upsert_ruleset "$ruleset"
upsert_ruleset "$tag_ruleset"
upsert_ruleset "$tag_creation_ruleset"

# 3. and 4. Each environment and its deployment branch and tag policies: exactly the wanted ones.
environment() { # environment <name> <wanted policies: a JSON array of {name, type}>
  local policies_path existing
  send PUT "repos/$REPO/environments/$1" \
    '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  policies_path="repos/$REPO/environments/$1/deployment-branch-policies"
  if ! existing=$(gh api "$policies_path" 2>/dev/null); then
    $dry_run || { echo "can't read $policies_path" >&2; exit 1; }
    existing='{"branch_policies":[]}' # the environment doesn't exist yet
  fi
  jq -c --argjson wanted "$2" '$wanted - [.branch_policies[] | {name, type}] | .[]' <<<"$existing" |
    while read -r policy; do send POST "$policies_path" "$policy"; done
  jq -r --argjson wanted "$2" '.branch_policies[] | select({name, type} as $p | $wanted | index([$p]) | not) | .id' \
    <<<"$existing" | while read -r extra; do send DELETE "$policies_path/$extra"; done
}
environment "$ENVIRONMENT" '[{"name":"main","type":"branch"},{"name":"v*","type":"tag"}]'
environment "$SMOKE_TEST_ENVIRONMENT" '[{"name":"main","type":"branch"}]'

if $dry_run; then
  echo "Dry run: nothing sent. Required checks:"; while read -r check; do echo "  $check"; done <<<"$checks"
  echo "v* tags: never deleted, moved or force-pushed; created only by repository admins and maintainers."
else
  echo "main is protected ($approvals approvals); v* tags are immutable and only admins and maintainers create them;"
  echo "environment $ENVIRONMENT deploys from main and v* tags only, environment $SMOKE_TEST_ENVIRONMENT from main only."
  echo "Next, if not done yet: the release secrets (docs/setup.md, \"Release secrets\") and the smoke test's email"
  echo "settings (docs/setup.md, \"Smoke test email\")."
fi
