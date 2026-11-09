#!/usr/bin/env bash
# Read or change the release an environment is pinned to (docs/git-workflow.md, "Promotion and rollback").
#
#   scripts/pin-release.sh prod              # prints prod's pinned release, e.g. 0.2.0
#   scripts/pin-release.sh prod 0.2.1        # pins prod to 0.2.1, its digests from releases/0.2.1.md: the edit a
#                                            # promotion (or rollback) PR makes
#   PIN_IMAGES=... scripts/pin-release.sh qa 0.3.0-rc.1   # release candidates too, their digests given
#   scripts/pin-release.sh --images prod     # prints each pinned image, <name>:<version>@sha256:<digest>
#   scripts/pin-release.sh --suspended qa    # exit 0: qa has no release yet (suspended); 1: it has one; 2: no pin
#
# The pin is every line in clusters/local/*.yaml ending in `# release-pin: <env>`: the environment's
# GitRepository `ref.semver` (the source at tag vX.Y.Z), and for each image of its Kustomization a `newTag` (the
# X.Y.Z image) and a `digest` (exactly that image: the image runs as <name>:X.Y.Z@sha256:..., so a tag repointed
# in the registry changes nothing). The version lines always hold the same exact version, so the release's manifests
# and images never diverge. Reading fails if the lines are missing, disagree, hold anything but an exact X.Y.Z or
# X.Y.Z-rc.N (scripts/lib/versions.sh), or an image has no sha256 digest line.
#
# Pinning takes each image's digest from PIN_IMAGES when set (one image per line, <name>:<version>@sha256:<digest>,
# as CI and sign-off list them; other lines are ignored), else, for a release X.Y.Z, from its record
# releases/X.Y.Z.md (its candidate's images, which X.Y.Z copies by digest): a rollback pins the recorded digests.
# It fails, changing nothing, when a pinned image has no digest there. A new `- name:` entry with only its `newTag`
# line gets its `digest` line from the next pin.
#
# An environment with no release yet (QA before its first release candidate) also has a `suspend: true` line
# ending in `# release-pin-until: <env>`: its pin is only a placeholder and Flux deploys nothing. Reading says so
# on stderr, and --suspended answers it; pinning a version deletes that line, so the first promotion also starts the
# environment. PIN_DIR overrides the folder (tests, sign-off reading main's pins); RELEASES_DIR the records' folder.
set -euo pipefail
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"

usage() {
  echo "usage: scripts/pin-release.sh <env> [X.Y.Z | X.Y.Z-rc.N]   |   scripts/pin-release.sh --images <env>" \
    "  |   scripts/pin-release.sh --suspended <env>" >&2
  exit 2
}
ask=""
case "${1:-}" in --suspended | --images) ask=$1; shift ;; esac
env=${1:-}
version=${2:-}
[[ "$env" =~ ^[a-z]+$ ]] || usage
if [ -n "$ask" ] && [ -n "$version" ]; then usage; fi

dir=${PIN_DIR:-"$(git rev-parse --show-toplevel)/clusters/local"}
marker="# release-pin: $env"
until="# release-pin-until: $env"
files=$(grep -l -- "$marker\$" "$dir"/*.yaml || true)
if [ -z "$files" ]; then
  echo "no '$marker' lines in $dir" >&2
  if [ "$ask" = --suspended ]; then exit 2; else exit 1; fi
fi

# shellcheck disable=SC2086 # $files is a list of paths without spaces
suspended() { grep -q -- " $until\$" $files; }
if [ "$ask" = --suspended ]; then
  suspended
  exit
fi

# The pin's images, "<name> <newTag> <digest>" per image (digest empty when its line is missing), in file order.
# shellcheck disable=SC2086 # $files is a list of paths without spaces
images() {
  awk -v m=" $marker" '
    function ends(s, t) { return length(s) >= length(t) && substr(s, length(s) - length(t) + 1) == t }
    function value(s) { sub(/^[^:]*: *"?/, "", s); sub(/"? *#.*$/, "", s); return s }
    function flush() { if (tag != "") print name, tag, digest; tag = ""; digest = "" }
    /^[[:space:]]*- name: / { flush(); name = $3 }
    ends($0, m) && $1 == "newTag:" { tag = value($0) }
    ends($0, m) && $1 == "digest:" { digest = value($0) }
    END { flush() }' $files
}

if [ -n "$version" ]; then
  is_pinnable "$version" || usage
  escaped=${version//./\\.}
  # "<name> <digest>" for each image the source lists at this version.
  if [ -n "${PIN_IMAGES:-}" ]; then
    source="PIN_IMAGES"
    digests=$(sed -nE "s|^[[:space:]]*([^[:space:]]+):$escaped@(sha256:[0-9a-f]{64})[[:space:]]*\$|\1 \2|p" <<<"$PIN_IMAGES")
  else
    record=${RELEASES_DIR:-"$(git rev-parse --show-toplevel)/releases"}/$version.md
    source=$record
    if ! is_release "$version" || [ ! -f "$record" ]; then
      echo "no digests for $version: give its images in PIN_IMAGES (<name>:$version@sha256:<digest>, one per line)" \
        "or, for a release, its record releases/$version.md" >&2
      exit 1
    fi
    # shellcheck disable=SC2016 # Markdown's backticks, not an expansion
    candidate=$(sed -nE 's/^Candidate: `v([^`]+)`$/\1/p' "$record" | head -n 1)
    { is_candidate "$candidate" && [ "$(release_of "$candidate")" = "$version" ]; } \
      || { echo "$record names no candidate of $version (a line \`Candidate: \`v$version-rc.N\`\`)" >&2; exit 1; }
    escaped=${candidate//./\\.}
    digests=$(sed -nE "s|.*\`([^\`[:space:]]+):$escaped@(sha256:[0-9a-f]{64})\`.*|\1 \2|p" "$record")
  fi
  missing=""
  while read -r name _; do
    awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' <<<"$digests" || missing+=" $name"
  done < <(images)
  [ -z "$missing" ] || { echo "no digest at $version for:$missing (in $source); nothing changed" >&2; exit 1; }
  for f in $files; do
    PIN_DIGESTS=$digests awk -v m=" $marker" -v u=" $until" -v v="$version" '
      function ends(s, t) { return length(s) >= length(t) && substr(s, length(s) - length(t) + 1) == t }
      BEGIN { n = split(ENVIRON["PIN_DIGESTS"], l, "\n"); for (i = 1; i <= n; i++) { split(l[i], p, " "); d[p[1]] = p[2] } }
      ends($0, u) { next }
      /^[[:space:]]*- name: / { name = $3 }
      ends($0, m) {
        if ($1 == "digest:") next
        key = $0; sub(/: .*$/, "", key)
        print key ": \"" v "\"" m
        if ($1 == "newTag:") { sub(/newTag$/, "", key); print key "digest: \"" d[name] "\"" m }
        next
      }
      { print }' "$f" >"$f.pin"
    mv "$f.pin" "$f"
  done
fi

# shellcheck disable=SC2086 # $files is a list of paths without spaces
values=$(grep -h -- "$marker\$" $files | grep -vE '^[[:space:]]*digest:' \
  | sed -E "s|.*: \"?([^\" #]*)\"? +$marker\$|\1|" | sort -u)
if [ "$(wc -l <<<"$values")" -ne 1 ] || ! is_pinnable "$values"; then
  echo "$env is not pinned to one exact release; '$marker' lines hold:" >&2
  echo "$values" >&2
  exit 1
fi
undigested=$(images | awk '$3 !~ /^sha256:[0-9a-f]{64}$/ { print $1 }')
if [ -n "$undigested" ]; then
  echo "$env pins no sha256 digest for: $(paste -sd ' ' - <<<"$undigested") (a 'digest:' line ending in '$marker'" \
    "under its newTag; scripts/pin-release.sh $env $values writes it)" >&2
  exit 1
fi
if [ "$ask" = --images ]; then
  images | awk '{ print $1 ":" $2 "@" $3 }'
  exit
fi
if suspended; then
  echo "$env has no release yet: its Kustomization is suspended and $values is a placeholder (not deployed)" >&2
fi
echo "$values"
