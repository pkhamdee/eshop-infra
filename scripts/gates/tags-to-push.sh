#!/usr/bin/env bash
# Which built image tags service-image.yml's push job may push: never one that already exists (#116). A second run of
# a commit (a re-run, a dispatch) would otherwise replace the image dev tested and Flux deployed with a rebuild,
# whose digest can differ, and a release candidate copies whatever dev's pin names (scripts/candidate-images.sh).
#
#   scripts/gates/tags-to-push.sh "$RUNNER_TEMP"/images/image-*/tags.txt
#
# Each tags.txt is one image: its tags, one per line (main-<sha> and main-<sha>-<ts>, or release-N.x-<sha>-<ts>). An image
# is all or nothing: when any of its tags exists, none is pushed (so main-<sha> never names a different build from
# main-<sha>-<ts>), and the skip is reported. Prints the tags to push, one per line, possibly none. Exit 1 when a
# repository's tags can't be read (unknown is not absent); a repository that doesn't exist yet has no tags. Needs
# crane. scripts/tests/release-scripts.sh tests it with a fake crane.
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: scripts/gates/tags-to-push.sh <tags.txt>..." >&2; exit 2; }

err=$(mktemp)
trap 'rm -f "$err"' EXIT
for file in "$@"; do
  existing=()
  tags=()
  while read -r image; do
    [ -n "$image" ] || continue
    tags+=("$image")
    repository=${image%:*}
    if ! listed=$(crane ls "$repository" 2>"$err"); then
      grep -q NAME_UNKNOWN "$err" && continue # no repository yet: nothing to overwrite
      cat "$err" >&2
      echo "could not list the tags of $repository, so can't tell whether $image exists" >&2
      exit 1
    fi
    if grep -qxF -- "${image##*:}" <<<"$listed"; then existing+=("$image"); fi
  done <"$file"
  if [ ${#existing[@]} -gt 0 ]; then
    echo "skipped ${tags[*]}: ${existing[*]} already exists, and an image is never overwritten (the one there is what" \
      "Flux deployed)" >&2
  elif [ ${#tags[@]} -gt 0 ]; then
    printf '%s\n' "${tags[@]}"
  fi
done
