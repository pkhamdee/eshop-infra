#!/usr/bin/env bash
# Sign off a release candidate (docs/git-workflow.md, "Sign-off"; ADR 0008): the sign-off workflow
# (.github/workflows/sign-off.yml) runs it on a push to main that adds or changes a release's record releases/X.Y.Z.md,
# i.e. when a sign-off PR (scripts/sign-off-pr.sh) is merged. It is not meant to be run by hand.
#
#   scripts/sign-off.sh <before> <after>   # the push: main's commit before it and after it
#
# The record names the candidate (a line `Candidate: `vX.Y.Z-rc.N``); who signed off is whoever merged the PR that
# brought in <after>. A push that adds or changes no record does nothing.
# Refuses, changing nothing (and failing, so the workflow run shows it), unless:
#   - the push adds or changes exactly one record, which names a candidate of its version, tag vX.Y.Z-rc.N on origin
#     (annotated);
#   - a merged PR brought in <after> (its merger signs off), and its merger is a maintainer of $REPO (repo role
#     admin or maintain): anyone else's merge signs off nothing, and the run fails saying so;
#   - origin/main pins eshop-qa to exactly that candidate and apps-qa is not suspended (scripts/pin-release.sh qa);
#   - QA's latest Deployment of vX.Y.Z-rc.N (e2e.yml, scripts/deployment.sh) created since main last changed QA's
#     pin succeeded (scripts/lib/qa.sh): older ones tested an earlier deployment. That run checked of the cluster that
#     QA served the candidate before and after the test (e2e/check-serving.sh);
#   - every candidate image $IMAGE_REGISTRY/<service>:X.Y.Z-rc.N (.github/services.json) exists, and any X.Y.Z image
#     that already exists has the candidate's digest;
#   - tag vX.Y.Z is absent, or is this candidate's sign-off (same commit, made by this script).
# Then, in this order, each step skipped or updated when an earlier run already did it, so a failed sign-off is
# finished by re-running the workflow's job:
#   1. copies each candidate image to X.Y.Z by digest (crane copy; never rebuilt) and checks the digest;
#   2. tags vX.Y.Z (annotated) on the candidate's commit and pushes it; images first, so the tag never names
#      images that don't exist. The tag message names the merger and the PR;
#   3. publishes (or updates) the GitHub Release vX.Y.Z: the images with digests, the QA Deployment and run, who
#      signed off in which PR;
#   4. opens (or updates) the prod promotion PR: scripts/promotion-pr.sh prod X.Y.Z.
#
# Environment: REPO and IMAGE_REGISTRY (defaults: scripts/lib/repo.sh), SIGN_OFF_RUN_URL (the workflow run, linked in
# the Release and PR), SIGN_OFF_READ_TOKEN (a token for the checks, e.g. the workflow's own; default: gh's token).
# Needs a clean checkout of main with <before> and <after>, push access to origin, `gh` with a token that may create
# Releases and PRs, crane logged in to the registry with push access, and jq. scripts/tests/release-scripts.sh tests
# it with fake gh and crane against a throwaway origin.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"
# shellcheck source=lib/repo.sh
. "$(dirname "$0")/lib/repo.sh"
# shellcheck source=lib/images.sh
. "$(dirname "$0")/lib/images.sh"
# shellcheck source=lib/qa.sh
. "$(dirname "$0")/lib/qa.sh"

usage() { echo "usage: scripts/sign-off.sh <before> <after>" >&2; exit 2; }
refuse() { echo "Sign-off refused: $*" >&2; exit 1; }

main() {
  [ $# -eq 2 ] || usage
  cd "$(git rev-parse --show-toplevel)"
  local after before
  after=$(git rev-parse --verify --quiet "$2^{commit}") || refuse "no commit $2 here"
  # No <before> (a new branch's all-zero SHA, a force push's lost commit): the last commit alone.
  before=$(git rev-parse --verify --quiet "$1^{commit}") || before=$(git rev-parse "$after^1")

  # --- Which release: the record this push added or changed ---

  local records
  records=$(git diff --name-only --diff-filter=AM "$before" "$after" -- 'releases/*.md')
  if [ -z "$records" ]; then
    echo "This push adds or changes no release record (releases/X.Y.Z.md): no release record, nothing to sign off"
    return 0
  fi
  [ "$(wc -l <<<"$records")" -eq 1 ] \
    || refuse "this push changes several release records ($(paste -sd ' ' <<<"$records")): a sign-off PR adds one"
  local record=$records version candidate
  version=$(basename "$record" .md)
  is_release "$version" || refuse "$record is not named after a release X.Y.Z"
  # shellcheck disable=SC2016 # Markdown's backticks, not an expansion
  candidate=$(git show "$after:$record" | sed -nE 's/^Candidate: `v([^`]+)`$/\1/p' | head -n 1)
  { is_candidate "$candidate" && [ "$(release_of "$candidate")" = "$version" ]; } \
    || refuse "$record names candidate ${candidate:-(none)}, which is not a candidate of $version (a line \`Candidate: \`v$version-rc.N\`\`)"
  local rc_tag="v$candidate" tag="v$version"
  local repo=$REPO registry=$IMAGE_REGISTRY

  # --- Checks: nothing is changed until every one passed ---

  local pr_number pr actor
  pr_number=$(gh_read api "repos/$repo/commits/$after/pulls" \
    --jq '[.[] | select(.merged_at != null)][0].number // empty') || refuse "could not read the PR that brought in $after"
  [ -n "$pr_number" ] || refuse "no merged pull request brought in $after: a release is signed off by merging its sign-off PR"
  read -r pr actor < <(gh_read api "repos/$repo/pulls/$pr_number" --jq '"\(.html_url) \(.merged_by.login // "")"') \
    || refuse "could not read PR #$pr_number"
  [ -n "$actor" ] || refuse "can't tell who merged $pr"
  local role
  role=$(gh_read api "repos/$repo/collaborators/$actor/permission" --jq .role_name) \
    || refuse "could not read $actor's role in $repo"
  if [ "$role" != admin ] && [ "$role" != maintain ]; then
    refuse "$actor merged $pr but is not a maintainer of $repo (role: $role); only admin or maintain may sign off." \
      "Revert the record's merge, or have a maintainer merge a new sign-off PR"
  fi

  git fetch --quiet origin main
  git fetch --quiet --force origin "refs/tags/$rc_tag:refs/tags/$rc_tag" 2>/dev/null \
    || refuse "release candidate $rc_tag is not on origin"
  [ "$(git cat-file -t "refs/tags/$rc_tag")" = tag ] || refuse "$rc_tag is not an annotated tag"
  local commit
  commit=$(git rev-parse "$rc_tag^{commit}")

  local tagged=false
  if [ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]; then
    git fetch --quiet --force origin "refs/tags/$tag:refs/tags/$tag"
    if [ "$(git rev-parse "$tag^{commit}")" != "$commit" ] \
      || ! git cat-file tag "refs/tags/$tag" | grep -qF "Signed off from $rc_tag by @"; then
      refuse "$tag already exists and is not a sign-off of $rc_tag: $version is released; cut the next version"
    fi
    tagged=true # an earlier sign-off of this candidate got this far: finish it
  fi

  local qa pinned=0
  qa=$(qa_pin) || pinned=$?
  case "$pinned" in
    0) ;;
    3) refuse "eshop-qa has no release yet on main (apps-qa is suspended): QA must be running $candidate" ;;
    *) refuse "eshop-qa's pin on main is unreadable" ;;
  esac
  [ "$qa" = "$candidate" ] || refuse "eshop-qa is pinned to $qa on main, not $candidate: QA must be running the candidate it signs off"

  local pinned_at deployment state qa_run qa_deployment_id
  pinned_at=$(qa_pinned_at)
  [ -n "$pinned_at" ] || refuse "can't find the commit on main that pinned eshop-qa"
  deployment=$(qa_deployment "$candidate" "$pinned_at") || refuse "could not read QA's Deployments"
  [ -n "$deployment" ] \
    || refuse "no Deployment of $rc_tag to qa since eshop-qa was pinned to it ($pinned_at): QA's smoke test of it" \
      "runs when its promotion is merged, or by hand: e2e/run-on-actions.sh qa $candidate"
  state=$(jq -r .state <<<"$deployment")
  qa_run=$(jq -r .log_url <<<"$deployment")
  qa_deployment_id=$(jq -r .id <<<"$deployment")
  [ "$state" = success ] \
    || refuse "QA's latest Deployment of $candidate is $state$(jq -r '.description | if . != "" then " (\(.))" else "" end' <<<"$deployment"): $qa_run"

  # Each service as "<service> <digest> <exists>": the candidate's digest, and whether X.Y.Z already exists.
  local images="" plan="" svc digest tags existing
  for svc in $(jq -r '.[].service' .github/services.json); do
    digest=$(crane digest "$registry/$svc:$candidate") || refuse "candidate image $registry/$svc:$candidate is missing"
    tags=$(crane ls "$registry/$svc") || refuse "could not list the tags of $registry/$svc"
    existing=false
    if grep -qxF -- "$version" <<<"$tags"; then
      [ "$(crane digest "$registry/$svc:$version")" = "$digest" ] \
        || refuse "$registry/$svc:$version already exists with a different digest than $candidate's ($digest); release images are never overwritten"
      existing=true
    fi
    plan+="$svc $digest $existing"$'\n'
    images+="$registry/$svc:$version@$digest"$'\n'
  done

  # --- Sign-off ---

  local copied
  while read -r svc digest existing; do
    [ -n "$svc" ] || continue
    if ! $existing; then crane copy "$registry/$svc@$digest" "$registry/$svc:$version"; fi
    copied=$(crane digest "$registry/$svc:$version")
    [ "$copied" = "$digest" ] || { echo "$registry/$svc:$version has digest $copied, not $digest" >&2; exit 1; }
    echo "$registry/$svc:$version@$digest"
  done <<<"$plan"

  if ! $tagged; then
    git tag --force -a "$tag" "$commit" -m "Release $version" \
      -m "Signed off from $rc_tag by @$actor, merging $pr. QA's Deployment $qa_deployment_id of it: $qa_run"
    git push --quiet origin "refs/tags/$tag"
  fi
  echo "Tag $tag on $commit"

  local notes
  notes=$(mktemp)
  # shellcheck disable=SC2064 # expand now: $notes is local
  trap "rm -f '$notes'" EXIT
  {
    echo "Release **$tag**, signed off by @$actor by merging $pr, from release candidate **$rc_tag** (commit $commit)."
    echo "Its record: [\`$record\`](https://github.com/$repo/blob/$after/$record)."
    echo
    echo "### Images"
    echo
    echo "Copied from $rc_tag by digest, never rebuilt:"
    echo
    image_list <<<"$images"
    echo
    echo "### QA"
    echo
    echo "QA's smoke test of $candidate against https://qa.eshop.localhost passed: GitHub Deployment $qa_deployment_id"
    echo "of \`$rc_tag\` to \`qa\`, [run]($qa_run). It checked that eshop-qa served exactly this candidate before and"
    echo "after the test."
    if [ -n "${SIGN_OFF_RUN_URL:-}" ]; then echo; echo "Signed off in [this run]($SIGN_OFF_RUN_URL)."; fi
    echo
    echo "### Deploying"
    echo
    echo "A release deploys nothing by itself: eshop-prod moves to $tag when the prod promotion PR"
    echo "\"eshop-prod: deploy $tag\" is merged (docs/git-workflow.md, \"Promotion and rollback\")."
  } >"$notes"
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    gh release edit "$tag" --repo "$repo" --notes-file "$notes" >/dev/null
  else
    gh release create "$tag" --repo "$repo" --verify-tag --title "$tag" --notes-file "$notes" >/dev/null
  fi
  local release
  release=$(gh release view "$tag" --repo "$repo" --json url --jq .url)
  echo "Release: $release"

  PROMOTION_IMAGES=$images PROMOTION_DETAILS=$(
    echo "### Sign-off"
    echo
    echo "Signed off by @$actor by merging $pr, from release candidate $rc_tag. QA's smoke test of it passed:"
    echo "Deployment $qa_deployment_id, [run]($qa_run)."
    echo "Release: $release${SIGN_OFF_RUN_URL:+ ([sign-off run]($SIGN_OFF_RUN_URL))}. The images are $rc_tag's, copied by digest."
  ) scripts/promotion-pr.sh prod "$version"
}

# All of it in main, read before it runs: promotion-pr.sh checks out another branch under this script.
main "$@"
