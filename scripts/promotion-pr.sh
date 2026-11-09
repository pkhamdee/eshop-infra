#!/usr/bin/env bash
# Open a promotion PR (docs/git-workflow.md, "Promotion and rollback"): a branch from origin/main whose only commit
# pins <env> to <version> (scripts/pin-release.sh), pushed, and a PR into main. Merging it is the approval.
#
#   scripts/promotion-pr.sh qa 0.3.0-rc.1                    # CI, after a release candidate's images are pushed
#   scripts/promotion-pr.sh prod 0.3.0                       # sign-off; a person may run it too (also rollbacks)
#   PROMOTION_PUSH=0 scripts/promotion-pr.sh qa 0.3.0-rc.1   # only the local branch and commit; prints the body
#
# The pin carries each image's digest (scripts/pin-release.sh), and the PR body lists the pinned images. From the
# environment:
#   PROMOTION_IMAGES    the images, one per line, image:<version>@sha256:<digest> (CI: the candidate's, as pushed;
#                       sign-off: the release's): the digests pinned. Without it, a release's come from its record
#                       releases/X.Y.Z.md (a rollback), and a candidate's from the registry now (crane digest: by hand)
#   PROMOTION_DETAILS   Markdown appended as is (CI: gate results and run link; sign-off: QA run, who signed off)
# Refuses a version whose tag vX.Y.Z[-rc.N] is not on origin. Re-running for the same version updates the branch
# and the open PR. Needs a clean checkout, push access to origin, crane for a candidate without PROMOTION_IMAGES and, unless PROMOTION_PUSH=0, `gh` authenticated
# with a token that may open PRs. Commits with the current git identity. The GitHub-specific part is the last
# step (`gh pr`); scripts/tests/release-scripts.sh tests it against a throwaway origin.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"
# shellcheck source=lib/images.sh
. "$(dirname "$0")/lib/images.sh"

usage() { echo "usage: scripts/promotion-pr.sh qa X.Y.Z-rc.N | prod X.Y.Z" >&2; exit 2; }
env=${1:-}
version=${2:-}
env_takes "$env" "$version" || { echo "eshop-$env takes $(env_grammar "$env"), not '$version'" >&2; usage; }
tag="v$version"
branch="promote/$env-$version"
title="eshop-$env: deploy $tag"

cd "$(git rev-parse --show-toplevel)"
git fetch --quiet origin main
if ! git fetch --quiet origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null; then
  echo "$tag is not on origin: promote only a version whose tag (and images) exist" >&2; exit 1
fi
commit=$(git rev-parse "$tag^{commit}")

git checkout --quiet -B "$branch" origin/main
first=false
if scripts/pin-release.sh --suspended "$env"; then first=true; fi
was=$(scripts/pin-release.sh "$env" 2>/dev/null)
images=${PROMOTION_IMAGES:-}
if [ -z "$images" ] && is_candidate "$version"; then
  # A candidate promoted by hand: its digests as the registry has them now, listed in the PR for review.
  for name in $(scripts/pin-release.sh --images "$env" | sed -E 's/:[^:@]*@.*$//'); do
    digest=$(crane digest "$name:$version") || { echo "image $name:$version is missing" >&2; exit 1; }
    images+="$name:$version@$digest"$'\n'
  done
fi
PIN_IMAGES=$images scripts/pin-release.sh "$env" "$version" >/dev/null
[ -n "$images" ] || images=$(scripts/pin-release.sh --images "$env")
if git diff --quiet; then
  echo "eshop-$env is already pinned to $version on main: nothing to promote" >&2; exit 0
fi
git commit --quiet -am "$title"

body=$(mktemp)
trap 'rm -f "$body"' EXIT
{
  if $first; then from="eshop-$env has no release yet"; else from="from v$was"; fi
  echo "Promotes **eshop-$env** to **$tag** (commit $commit; $from). Merging this PR is the approval: Flux then"
  echo "deploys it to https://$env.eshop.localhost within a minute or two."
  echo
  echo "The only change is the pin: \`scripts/pin-release.sh $env $version\`, each image pinned by its digest."
  if $first; then
    echo "This is eshop-$env's first release: the same edit removes its suspend line, so merging it starts eshop-$env."
  fi
  echo
  echo "### Images"
  echo
  image_list <<<"$images"
  if [ -n "${PROMOTION_DETAILS:-}" ]; then
    echo
    echo "$PROMOTION_DETAILS"
  fi
} >"$body"

if [ "${PROMOTION_PUSH:-1}" = 0 ]; then
  echo "Branch $branch (not pushed): $title"
  echo
  cat "$body"
  exit 0
fi

git push --quiet --force origin "HEAD:refs/heads/$branch"
pr=$(gh pr list --base main --head "$branch" --state open --json url --jq '.[0].url // empty')
if [ -n "$pr" ]; then
  gh pr edit "$pr" --title "$title" --body-file "$body" >/dev/null
else
  pr=$(gh pr create --base main --head "$branch" --title "$title" --body-file "$body")
fi
echo "Promotion PR: $pr"
