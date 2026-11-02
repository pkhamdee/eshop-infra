#!/usr/bin/env bash
# CI's rule for a pushed v* tag (ci-release.yml, `plan`; docs/git-workflow.md, "Releasing"):
#
#   scripts/check-release-tag.sh v0.3.0-rc.1   # prints 0.3.0-rc.1: build, gate and push it as a release candidate
#   scripts/check-release-tag.sh v0.3.0        # prints nothing (and says why on stderr): a release, made by sign-off
#                                              # from a candidate's images, is never built
#
# A release candidate must be vX.Y.Z-rc.N, annotated, and on a release/N.x branch; anything else exits 1. Run in a
# full clone (remote branches fetched) with the tag present locally. scripts/tests/release-scripts.sh tests it.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"

tag=${1:?usage: scripts/check-release-tag.sh <tag>}
version=${tag#v}

if [ "$tag" = "v$version" ] && is_release "$version"; then
  echo "$tag is a release: sign-off (a merged sign-off PR, sign-off.yml) tags it and copies the candidate's images," \
    "so CI builds nothing for it" >&2
  exit 0
fi
if [ "$tag" != "v$version" ] || ! is_candidate "$version"; then
  echo "Tag '$tag' is not vX.Y.Z-rc.N (a release candidate) or vX.Y.Z (a release)" >&2; exit 1
fi
if [ "$(git cat-file -t "refs/tags/$tag")" != "tag" ]; then
  echo "Tag '$tag' is lightweight; release tags must be annotated (git tag -a)" >&2; exit 1
fi
if ! git branch -r --contains "refs/tags/$tag" | grep -qE '^\s*origin/release/[0-9]+\.x$'; then
  echo "Tag '$tag' is not on any release/N.x branch" >&2; exit 1
fi
echo "$version"
