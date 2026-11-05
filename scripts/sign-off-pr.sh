#!/usr/bin/env bash
# The sign-off PR (docs/git-workflow.md, "Sign-off"; ADR 0008): keeps the open sign-off PRs in line with what QA runs
# and how its smoke test went. e2e.yml runs it on main after each QA smoke test; it is safe to run again.
#
#   scripts/sign-off-pr.sh
#
# From the candidate X.Y.Z-rc.N that origin/main pins eshop-qa to, and QA's latest Deployment of vX.Y.Z-rc.N created
# since main last changed QA's pin (scripts/lib/qa.sh; an older one tested an earlier deployment):
#   - success, and vX.Y.Z not yet released: opens (or updates) the PR "Sign off vX.Y.Z-rc.N" from branch
#     sign-off/X.Y.Z-rc.N, made from origin/main, whose only commit adds the release's record releases/X.Y.Z.md: the
#     candidate and its commit, its images with digests, the passing run, its Playwright report and the Deployment.
#     One PR per candidate: when the open PR's record already says the same, nothing is pushed. Merging it is the
#     sign-off (.github/workflows/sign-off.yml runs scripts/sign-off.sh);
#   - every other open sign-off PR is closed with a comment saying why: QA is pinned to another candidate (or to
#     none), or QA's latest smoke test of the candidate did not pass. While that test is running, or there is none
#     since the pin, the candidate's own PR is left open.
#
# Environment: REPO and IMAGE_REGISTRY (defaults: scripts/lib/repo.sh), SIGN_OFF_READ_TOKEN (a token for the reads,
# e.g. the workflow's own; default: gh's token). Needs a clean checkout, push access to origin, `gh` with a token that
# may open and close PRs (PROMOTION_TOKEN: a PR opened with GITHUB_TOKEN would get no checks), crane (the candidate's
# digests; reads only) and jq. Commits with the current git identity. scripts/tests/release-scripts.sh tests it with
# fake gh and crane against a throwaway origin.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"
# shellcheck source=lib/repo.sh
. "$(dirname "$0")/lib/repo.sh"
# shellcheck source=lib/images.sh
. "$(dirname "$0")/lib/images.sh"
# shellcheck source=lib/qa.sh
. "$(dirname "$0")/lib/qa.sh"

cd "$(git rev-parse --show-toplevel)"
git fetch --quiet origin main

# --- What QA runs, and how its latest smoke test of it went ---

candidate="" pinned=0
candidate=$(qa_pin) || pinned=$?
case "$pinned" in
  0) qa_now="eshop-qa is pinned to $candidate on main" ;;
  3) qa_now="eshop-qa runs no release candidate on main (apps-qa is suspended)" ;;
  *) echo "eshop-qa's pin on main is unreadable" >&2; exit 1 ;;
esac

deployment="" state="" open=false
if [ -n "$candidate" ]; then
  version=$(release_of "$candidate")
  pinned_at=$(qa_pinned_at)
  deployment=$(qa_deployment "$candidate" "$pinned_at")
  if [ -z "$deployment" ]; then
    echo "QA has no Deployment of v$candidate to qa since eshop-qa was pinned to it ($pinned_at): nothing to sign off yet"
  else
    state=$(jq -r .state <<<"$deployment")
    if [ "$state" != success ]; then
      echo "QA's latest Deployment of v$candidate is $state: nothing to sign off yet"
    elif git ls-remote --exit-code --tags origin "refs/tags/v$version" >/dev/null; then
      echo "v$version is already released: nothing to sign off"
    else
      open=true
    fi
  fi
fi

# --- Close the sign-off PRs that no longer hold ---

while read -r head url; do
  [ -n "$head" ] || continue
  other=${head#sign-off/}
  if [ "$other" != "$candidate" ]; then
    reason="$qa_now, not $other"
  else
    case "$state" in
      success | in_progress | queued | pending | "") continue ;; # it holds, or its test is still to come
    esac
    reason="QA's latest smoke test of $candidate did not pass ($state$(jq -r '.description | if . != "" then ": \(.)" else "" end' <<<"$deployment")): $(jq -r .log_url <<<"$deployment")"
  fi
  gh pr close "$head" --repo "$REPO" --delete-branch --comment "Closed by the pipeline (scripts/sign-off-pr.sh): $reason.
So v$other can't be signed off. A new sign-off PR opens when QA's smoke test of the candidate it runs passes." >/dev/null
  echo "Closed $url: $reason"
done < <(gh pr list --repo "$REPO" --base main --state open --limit 100 --json headRefName,url \
  --jq '.[] | select(.headRefName | startswith("sign-off/")) | "\(.headRefName) \(.url)"')

$open || exit 0

# --- Open (or update) the candidate's sign-off PR ---

rc_tag="v$candidate" branch="sign-off/$candidate" file="releases/$version.md" title="Sign off v$candidate"
git fetch --quiet --force origin "refs/tags/$rc_tag:refs/tags/$rc_tag" \
  || { echo "release candidate $rc_tag is not on origin" >&2; exit 1; }
commit=$(git rev-parse "$rc_tag^{commit}")
images=""
for svc in $(jq -r '.[].service' .github/services.json); do
  digest=$(crane digest "$IMAGE_REGISTRY/$svc:$candidate") \
    || { echo "candidate image $IMAGE_REGISTRY/$svc:$candidate is missing" >&2; exit 1; }
  images+="$IMAGE_REGISTRY/$svc:$candidate@$digest"$'\n'
done
read -r id created log_url < <(jq -r '"\(.id) \(.created_at) \(.log_url)"' <<<"$deployment")
# The run's Playwright report: e2e.yml uploads it as artifact playwright-report-qa.
report=""
if [[ "$log_url" =~ /actions/runs/([0-9]+)$ ]]; then
  report=$(gh_read api "repos/$REPO/actions/runs/${BASH_REMATCH[1]}/artifacts" \
    --jq '.artifacts[] | select(.name == "playwright-report-qa") | .id' | head -n 1) || report=""
fi

record=$(mktemp)
body=$(mktemp)
trap 'rm -f "$record" "$body"' EXIT
{
  echo "# Release $version"
  echo
  echo "Candidate: \`$rc_tag\`"
  echo
  echo "Commit $commit. Signed off by merging the PR that added this file: the sign-off workflow then tagged"
  echo "\`v$version\` on that commit, naming who merged it (\`git show v$version\`, \`gh release view v$version\`)."
  echo
  echo "## Images"
  echo
  echo "The candidate's, copied to \`$version\` by digest at sign-off, never rebuilt:"
  echo
  image_list <<<"$images"
  echo
  echo "## QA"
  echo
  echo "QA's smoke test of $rc_tag passed against https://qa.eshop.localhost: GitHub Deployment $id of \`$rc_tag\` to"
  echo "\`qa\`, created $created, success."
  echo
  echo "- Run: $log_url"
  if [ -n "$report" ]; then
    echo "- Playwright report: $log_url/artifacts/$report (playwright-report-qa)"
  else
    echo "- Playwright report: not found in the run (artifact playwright-report-qa)"
  fi
} >"$record"

pr=$(gh pr list --repo "$REPO" --base main --head "$branch" --state open --json url --jq '.[0].url // empty')
if [ -n "$pr" ] && git fetch --quiet origin "refs/heads/$branch" 2>/dev/null \
  && git show "FETCH_HEAD:$file" 2>/dev/null | cmp -s - "$record"; then
  echo "Sign-off PR $pr is up to date"
  exit 0
fi

git checkout --quiet -B "$branch" origin/main
mkdir -p releases
cp "$record" "$file"
git add "$file"
if git diff --cached --quiet; then
  echo "$file on main already says this: nothing to sign off" >&2; exit 0
fi
git commit --quiet -m "$title"
git push --quiet --force origin "HEAD:refs/heads/$branch"

{
  echo "QA's smoke test of **$rc_tag** passed. **Merging this PR is the sign-off** of release **v$version**"
  echo "(docs/git-workflow.md, \"Sign-off\"), and only a maintainer's merge counts (repo role admin or maintain)."
  echo "The merge runs the sign-off workflow, which checks again that main"
  echo "still pins eshop-qa to $candidate and that QA's latest Deployment of it since that pin succeeded, then copies"
  echo "the images to \`$version\` by digest, tags \`v$version\` naming who merged, publishes the GitHub Release and"
  echo "opens the prod promotion PR."
  echo
  echo "This PR is closed automatically if QA moves to another candidate or its next smoke test of $candidate fails."
  echo "It adds only the release's record, \`$file\`:"
  echo
  echo "---"
  echo
  sed 's/^#/##/' "$record"
} >"$body"

if [ -n "$pr" ]; then
  gh pr edit "$pr" --repo "$REPO" --title "$title" --body-file "$body" >/dev/null
else
  pr=$(gh pr create --repo "$REPO" --base main --head "$branch" --title "$title" --body-file "$body")
fi
echo "Sign-off PR: $pr"
