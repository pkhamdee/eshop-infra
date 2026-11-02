#!/usr/bin/env bash
# Cut a release candidate per docs/git-workflow.md: annotated tag vX.Y.Z-rc.N on release/<MAJOR>.x, pushed, CI run
# confirmed. CI gates the candidate, pushes its X.Y.Z-rc.N images and opens the QA promotion PR.
#
#   scripts/release.sh 0.3.0-rc.1   # a new minor's first candidate: creates release/0.x from origin/main, or, when
#                                   # release/0.x exists, first merges origin/main into it (below)
#   scripts/release.sh 0.3.0-rc.2   # the next candidate: the fix must already be on release/0.x (and on main)
#   scripts/release.sh 0.2.1-rc.1   # a patch's candidate, cut the same way: tags the branch head
#   scripts/release.sh --force 0.3.0-rc.1   # skips the dev check below; the tag message records that it did
#
# A new minor's first candidate (X.Y.0-rc.1) on an existing release/N.x must contain main's work, so it tags a merge
# commit whose tree is exactly origin/main's, with parents the branch head and origin/main ("Merge main into
# release/N.x for vX.Y.0-rc.1", as v0.2.0 was made by hand in f613dcb). It refuses unless every commit on the branch
# since its last such merge is already on main by patch-id (`git cherry`): a fix only on the release branch would
# otherwise be lost (docs/git-workflow.md, "The one rule"). Any other candidate (X.Y.Z-rc.N with Z > 0 or N > 1)
# tags the branch head.
#
# A candidate that brings in origin/main (a new release/N.x, or the merge above) bundles everything on main, so it is
# cut only from a main commit that passed on dev (ADR 0008): dev's latest Deployment of exactly that commit (made by
# e2e.yml on main, scripts/deployment.sh; one recorded by a run from another branch is ignored) must be success.
# Still in progress, it refuses and says to wait; failed, inactive (superseded) or missing, it refuses and says why,
# with the run's link. --force cuts it anyway and adds "Cut with
# --force: dev's Deployment of <commit> was <state>" to the tag message. Candidates tagging the branch head are not
# checked: they bring in nothing from main.
#
# The release itself (plain vX.Y.Z) is not cut here: sign-off (merging the sign-off PR, sign-off.yml) tags it on the
# signed-off candidate's commit, so this script refuses X.Y.Z and points there.
#
# Refuses a candidate for a version already released, and when the commit to tag carries a GitHub skip-ci marker:
# GitHub would skip the tag push too, leaving a tag that never builds and, tags being immutable, can only be
# replaced by the next candidate. After pushing it waits for the tag's CI run to start and prints its URL.
# Releasing is a human step: agents are not allowed to push release tags. scripts/tests/release-scripts.sh tests it.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"
# shellcheck source=lib/repo.sh
. "$(dirname "$0")/lib/repo.sh"
# shellcheck source=lib/deployments.sh
. "$(dirname "$0")/lib/deployments.sh"

force=false
[ "${1:-}" = --force ] && { force=true; shift; }
[ "${2:-}" = --force ] && force=true
version=${1:-}
if is_release "$version"; then
  echo "scripts/release.sh no longer tags a release: cut a release candidate (scripts/release.sh $version-rc.N)," \
    "promote it to QA; once QA passes, merging its sign-off PR \"Sign off v$version-rc.N\" tags v$version" \
    "(docs/git-workflow.md, \"Releasing\")." >&2
  exit 2
fi
[[ "$version" =~ $CANDIDATE ]] || { echo "usage: scripts/release.sh [--force] X.Y.Z-rc.N" >&2; exit 2; }
release="v${BASH_REMATCH[1]}"
tag="v$version"
branch="release/${BASH_REMATCH[2]}.x"
new_minor=false
[ "${BASH_REMATCH[4]}" = 0 ] && [ "${BASH_REMATCH[5]}" = 1 ] && new_minor=true

cd "$(git rev-parse --show-toplevel)"
git fetch --quiet --tags origin
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "$tag already exists (tags are immutable: cut the next candidate)" >&2; exit 1
fi
if git rev-parse -q --verify "refs/tags/$release" >/dev/null; then
  echo "$release is already released: cut a candidate for the next version" >&2; exit 1
fi

merge=false
if git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
  commit=$(git rev-parse "origin/$branch")
  new_branch=false
  if $new_minor && [ "$(git rev-parse "$commit^{tree}")" != "$(git rev-parse 'origin/main^{tree}')" ]; then
    merge=true
  fi
else
  commit=$(git rev-parse origin/main)
  new_branch=true
fi

if $merge; then
  # The branch's own commits since its last merge from main (a merge whose tree is its main parent's, so everything
  # before it is superseded by that tree) must all be on main by patch-id; `git cherry` marks the others "+".
  since=""
  for candidate in $(git rev-list --first-parent --merges "origin/main..$commit"); do
    second=$(git rev-parse -q --verify "$candidate^2") || continue
    if git merge-base --is-ancestor "$second" origin/main \
      && [ "$(git rev-parse "$candidate^{tree}")" = "$(git rev-parse "$second^{tree}")" ]; then
      since=$candidate
      break
    fi
  done
  missing=$(git cherry origin/main "$commit" ${since:+"$since"} | sed -n 's/^+ //p')
  if [ -n "$missing" ]; then
    for c in $missing; do git log -1 --format='  %h %s' "$c" >&2; done
    echo "$branch has the commits above that are not on main (by patch-id), so merging main in for $tag would" \
      "drop them. Land each on main first (docs/git-workflow.md, \"The one rule\"), then run this again." >&2
    exit 1
  fi
fi
main_commit=$(git rev-parse origin/main)

# GitHub's skip markers, matched case-insensitively anywhere in the head commit message. A merge made below carries
# this script's own message, so only a commit tagged as it is can carry one.
if ! $merge && git log -1 --format=%B "$commit" | grep -qiE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]'; then
  git log -1 --format='%h %s' "$commit" >&2
  echo "carries a skip-ci marker, so GitHub would not build $tag. Land a commit without one on" \
    "$( $new_branch && echo main || echo "$branch" ) first." >&2
  exit 1
fi

# A candidate bringing in origin/main bundles everything on it, so dev's smoke test (e2e.yml, recorded as a Deployment
# by scripts/deployment.sh) must have passed on exactly that commit: its latest Deployment to dev recorded by a run on
# main (scripts/lib/deployments.sh), latest status.
forced=""
if $new_branch || $merge; then
  short=$(git rev-parse --short "$main_commit")
  id=$(deployments_of dev "sha=$main_commit" | head -n 1)
  id=${id%% *}
  state="" run="" why=""
  if [ -n "$id" ]; then
    status=$(latest_status "$id")
    state=$(jq -r .state <<<"$status")
    run=$(jq -r '.log_url // ""' <<<"$status")
    why=$(jq -r '.description // ""' <<<"$status")
  fi
  case "$state" in
    success) problem="" ;;
    "") problem="dev has no Deployment of main at $short: its smoke test (e2e.yml) never ran on it" ;;
    in_progress | queued | pending)
      problem="dev's smoke test of main at $short is still running ($state): wait for it to finish, then run this again" ;;
    failure | error) problem="dev's smoke test of main at $short failed${why:+: $why}" ;;
    inactive) problem="dev's Deployment of main at $short is inactive${why:+ ($why)}: its smoke test never finished" ;;
    *) problem="dev's Deployment of main at $short is $state" ;;
  esac
  if [ -n "$problem" ]; then
    echo "$problem${run:+ ($run)}." >&2
    if ! $force; then
      echo "A candidate bundles everything on main, so it is cut only from a commit that passed on dev" \
        "(docs/git-workflow.md, \"Releasing\"). --force cuts it anyway and records that in the tag message." >&2
      exit 1
    fi
    forced="Cut with --force: dev's Deployment of $main_commit was ${state:-missing}${run:+ ($run)}."
    echo "--force: cutting it anyway; the tag message records it." >&2
  fi
fi

echo "Release candidate $tag"
if $merge; then
  echo "  first, merge origin/main into $branch: a merge commit with main's tree, pushed to $branch, then tagged"
  echo "    $branch  $(git log -1 --format='%h %s' "$commit")"
  echo "    main         $(git log -1 --format='%h %s' "$main_commit")"
else
  echo "  commit  $(git log -1 --format='%h %s' "$commit")"
fi
if $new_branch; then echo "  branch  $branch (new, from origin/main)"; else echo "  branch  $branch"; fi
read -r -p "Push? [y/N] " answer
[ "$answer" = y ] || [ "$answer" = Y ] || { echo "aborted"; exit 1; }

if $merge; then
  commit=$(git commit-tree "$main_commit^{tree}" -p "$commit" -p "$main_commit" \
    -m "Merge main into $branch for $tag" \
    -m "Starts $release from main ($(git rev-parse --short "$main_commit")). Every commit of $branch since its last merge from main is already on main (git cherry).")
  git push --quiet origin "$commit:refs/heads/$branch"
elif $new_branch; then
  git push --quiet origin "$commit:refs/heads/$branch"
fi
git tag -a "$tag" -m "Release candidate $version" ${forced:+-m "$forced"} "$commit"
git push --quiet origin "refs/tags/$tag"

# The run appears within seconds; none after a minute means GitHub skipped it.
for _ in $(seq 30); do
  run=$(gh run list --repo "$REPO" --workflow ci-release.yml --branch "$tag" --limit 1 --json url --jq '.[0].url // empty')
  if [ -n "$run" ]; then
    echo "CI: $run"
    echo "Then: once its images are pushed, CI opens the QA promotion PR \"eshop-qa: deploy $tag\"; merging it" \
      "deploys the candidate to eshop-qa (docs/git-workflow.md, \"Releasing\")."
    exit 0
  fi
  sleep 2
done
echo "No CI run for $tag after a minute: check Actions for a skipped or failed run." >&2
exit 1
