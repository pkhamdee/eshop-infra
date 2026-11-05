#!/usr/bin/env bash
# Where each image of a release candidate comes from (ADR 0009), for CI's `plan` on a vX.Y.Z-rc.N tag
# (ci-release.yml): copied by digest from an image that already passed the gates, or built at the tag.
#
#   scripts/candidate-images.sh v0.5.0-rc.1
#   # -> {"source":"dev pins of main 1a2b3c…","build":[],"copy":[{"service":"eshop-api","image":"docker.io/…@sha256:…"},…]}
#
# Two kinds of candidate (scripts/release.sh):
#   - one that brings in main: the tag is on a main commit (a new release/N.x), or on the merge release.sh makes
#     (tree = its second parent's, a main commit). release.sh cut it only once dev's smoke test passed on that main
#     commit, so every service is copied from the image that commit's dev pins name (deploy/apps/dev and
#     deploy/thirdparty, the `{"$imagepolicy": "<namespace>:<service>:tag"}` lines): QA gets the bytes dev tested.
#   - one on a release branch's head (a patch, or rc.N > 1 after a fix): each service whose `paths`
#     (.github/services.json) changed since the previous v* tag on the branch is built at the tag; every other is
#     copied from that previous version's image. A change to ci-release.yml or services.json builds every service.
#     A service built in its own repository (`repository` in services.json) is never built here. Its patch is built
#     there, on its release/N.x, as release-N.x-<sha>-<ts> (service-image.yml): the newest such image made after the
#     previous tag (<ts>, its commit's time, later than the tag's) is swapped in; with none, the previous version's
#     image is copied. An older one belongs to an earlier minor's patches, never to this one.
#
# Prints one JSON object: source (a sentence for logs), build (services.json entries to build) and copy
# ({service, image} with image as repository@digest). Exits 1 naming what it can't resolve: a pin or an image that
# is missing is never filled in with something untested. Run in a full clone (origin/main and the tags fetched),
# with crane able to read $IMAGE_REGISTRY. scripts/tests/release-scripts.sh tests it with a fake crane.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"
# shellcheck source=lib/repo.sh
. "$(dirname "$0")/lib/repo.sh"

tag=${1:?usage: scripts/candidate-images.sh vX.Y.Z-rc.N}
is_candidate "${tag#v}" || { echo "$tag is not a release candidate tag vX.Y.Z-rc.N" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
commit=$(git rev-parse "$tag^{commit}")
services=$(jq -c . .github/services.json)
local_services=$(jq -c 'map(select(.repository == null))' <<<"$services") # the ones built from this repository

# The main commit the candidate brings in, if any.
source_main=""
if git merge-base --is-ancestor "$commit" origin/main; then
  source_main=$commit
elif second=$(git rev-parse -q --verify "$commit^2") \
  && git merge-base --is-ancestor "$second" origin/main \
  && [ "$(git rev-parse "$commit^{tree}")" = "$(git rev-parse "$second^{tree}")" ]; then
  source_main=$second
fi

# digest_of <repository:tag>: repository@digest, or exit naming the image.
digest_of() {
  local digest
  digest=$(crane digest "$1") || { echo "image $1 is missing, so $tag can't copy it" >&2; exit 1; }
  echo "${1%:*}@$digest"
}

# newest_patch <repository>: the newest release-N.x-<sha>-<ts> tag of this candidate's release line made after the
# previous tag (<ts> later than $since), or nothing. A repository that doesn't exist has none; an unreadable registry
# stops the run.
newest_patch() {
  local listed err
  err=$(mktemp)
  if ! listed=$(crane ls "$1" 2>"$err"); then
    if grep -q NAME_UNKNOWN "$err"; then rm -f "$err"; return 0; fi
    cat "$err" >&2; rm -f "$err"
    echo "could not list the tags of $1, so can't tell whether $tag patches it" >&2
    exit 1
  fi
  rm -f "$err"
  grep -E "^${line//./\\.}[0-9a-f]+-[0-9]+$" <<<"$listed" \
    | awk -F- -v since="$since" '$NF > since' | sort -t- -k4,4n | tail -n 1 || true
}

copy="[]" build="[]"
if [ -n "$source_main" ]; then
  short=$(git rev-parse --short "$source_main")
  source="dev pins of main $source_main"
  for svc in $(jq -r '.[].service' <<<"$services"); do
    pin=$(git grep -h -E "newTag: .*\{\"\\\$imagepolicy\": \"[a-z0-9-]+:$svc:tag\"\}" "$source_main" -- deploy/apps/dev deploy/thirdparty \
      | sed -E 's/^.*newTag: *"?([^" #]+)"?.*$/\1/' | head -n 1) || pin=""
    [ -n "$pin" ] || { echo "main at $short pins no image of $svc in deploy/apps/dev or deploy/thirdparty" >&2; exit 1; }
    image=$(digest_of "$IMAGE_REGISTRY/$svc:$pin")
    copy=$(jq -c --arg s "$svc" --arg i "$image" '. + [{service: $s, image: $i}]' <<<"$copy")
  done
else
  previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$commit^" 2>/dev/null) \
    || { echo "$tag is on a release branch's head, but no earlier v* tag is reachable from it to copy images from" >&2; exit 1; }
  is_pinnable "${previous#v}" || { echo "the previous tag $previous is not a release or a candidate" >&2; exit 1; }
  since=$(git for-each-ref --format='%(creatordate:unix)' "refs/tags/$previous")
  version=${tag#v}
  line="release-${version%%.*}.x-" # service repositories' patch images for this release/N.x
  patched=()
  changed=$(git diff --name-only "$previous" "$commit")
  if grep -qxE '\.github/workflows/ci-release\.yml|\.github/services\.json' <<<"$changed"; then
    build=$local_services
  else
    build=$(jq -c --arg changed "$changed" '
      ($changed | split("\n")) as $files
      | [ .[] | select(.paths as $p | any($files[]; . as $f | any($p[]; . as $prefix | $f | startswith($prefix)))) ]
    ' <<<"$local_services")
  fi
  for svc in $(jq -r --argjson build "$build" '.[] | .service as $s | select($build | map(.service) | index($s) | not) | .service' <<<"$services"); do
    patch=""
    if [ "$(jq -r --arg s "$svc" '.[] | select(.service == $s) | .repository // empty' <<<"$services")" != "" ]; then
      patch=$(newest_patch "$IMAGE_REGISTRY/$svc")
    fi
    if [ -n "$patch" ]; then
      image=$(digest_of "$IMAGE_REGISTRY/$svc:$patch")
      patched+=("$svc:$patch")
    else
      image=$(digest_of "$IMAGE_REGISTRY/$svc:${previous#v}")
    fi
    copy=$(jq -c --arg s "$svc" --arg i "$image" '. + [{service: $s, image: $i}]' <<<"$copy")
  done
  source="$previous's images"
  [ ${#patched[@]} -eq 0 ] || source+=", patched with ${patched[*]}"
  [ "$build" = "[]" ] || source+=", rebuilding what changed here since"
fi

jq -cn --arg source "$source" --argjson build "$build" --argjson copy "$copy" '{source: $source, build: $build, copy: $copy}'
