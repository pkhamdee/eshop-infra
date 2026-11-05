#!/usr/bin/env bash
# Puts downloaded image artifacts where the image pipeline's jobs look for them: <dir>/image-<service>/{image.tar,
# tags.txt}. actions/download-artifact with `pattern:` makes one folder per artifact only when more than one
# matches; a single match lands directly in <dir>. This moves such a flat download into image-<service>, the service
# read from the repository of its first tag (docker.io/pkhamdee/<service>:<tag>). Anything else is left as it is.
#
#   scripts/gates/artifact-dirs.sh "$RUNNER_TEMP/images"     # after each download of pattern image-* (ci-release.yml,
#                                                            # service-image.yml)
set -euo pipefail

dir=${1:?usage: scripts/gates/artifact-dirs.sh <download folder>}
[ -f "$dir/tags.txt" ] || exit 0 # nothing downloaded, or already one folder per artifact
first=$(head -n 1 "$dir/tags.txt")
repository=${first%:*}
service=${repository##*/}
[[ "$service" =~ ^[a-z0-9-]+$ ]] || { echo "can't tell the service from tag '$first' in $dir/tags.txt" >&2; exit 1; }
mkdir -p "$dir/image-$service"
mv "$dir/tags.txt" "$dir/image-$service/"
[ ! -f "$dir/image.tar" ] || mv "$dir/image.tar" "$dir/image-$service/"
echo "single artifact moved to $dir/image-$service"
