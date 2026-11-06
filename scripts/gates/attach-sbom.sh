#!/usr/bin/env bash
# Attaches an image's CycloneDX SBOM to its digest in the registry, as an unsigned OCI referrer (ADR 0010). The push
# jobs run it after pushing (service-image.yml, ci-release.yml).
#
#   scripts/gates/attach-sbom.sh [--earlier-build] <registry/repository:tag> <sbom.cdx.json>
#
# The digest the tag names gets the SBOM, so a candidate or release copied from it by digest in the same repository
# (crane copy: scripts/candidate-images.sh, scripts/sign-off.sh) has it too. Never replaces one: when the digest
# already has a CycloneDX referrer, it is kept and nothing is attached, so a re-run only fills in a missing SBOM.
# --earlier-build: the tag was not pushed by this run (scripts/gates/tags-to-push.sh skipped it, #116), so the
# registry holds an earlier build that <sbom.cdx.json> (from this run's rebuild) may not describe. If that image has
# no SBOM, one is made from the registry digest itself (scripts/gates/sbom.sh, or $SBOM_GENERATOR).
#
# Needs crane and oras, logged in to push (oras reads Docker's credentials). Exit 1 when the registry can't be read
# (unknown is not absent) or the attach fails. scripts/tests/release-scripts.sh tests it with fake crane and oras.
set -euo pipefail

ARTIFACT_TYPE=application/vnd.cyclonedx+json

earlier=false
if [ "${1:-}" = --earlier-build ]; then earlier=true; shift; fi
[ $# -eq 2 ] || { echo "usage: scripts/gates/attach-sbom.sh [--earlier-build] <registry/repository:tag> <sbom.cdx.json>" >&2; exit 2; }
image=$1 sbom=$2
generator=${SBOM_GENERATOR:-$(dirname "$0")/sbom.sh}

digest=$(crane digest "$image") || { echo "could not read the digest of $image" >&2; exit 1; }
ref="${image%:*}@$digest"

if ! referrers=$(oras discover --artifact-type "$ARTIFACT_TYPE" --format json "$ref"); then
  echo "could not list the referrers of $ref, so can't tell whether it has an SBOM" >&2
  exit 1
fi
if [ "$(jq '.referrers | length' <<<"$referrers")" -gt 0 ]; then
  echo "$image ($digest) already has an SBOM: kept"
  exit 0
fi

if $earlier; then
  echo "$image is an earlier build than this run's and has no SBOM: making one from $ref"
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  repository=${image%:*}
  REPORT_DIR=$dir "$generator" "$ref"
  sbom="$dir/${repository##*/}.cdx.json"
fi
[ -f "$sbom" ] || { echo "no SBOM at $sbom" >&2; exit 1; }

# From the SBOM's folder, so the attached file's title is its name, not a runner path.
(cd "$(dirname "$sbom")" && oras attach --artifact-type "$ARTIFACT_TYPE" "$ref" "$(basename "$sbom"):$ARTIFACT_TYPE" >/dev/null)
echo "$image ($digest): SBOM attached"
