#!/usr/bin/env bash
# SBOM: a CycloneDX JSON SBOM of each built image (ADR 0010), with Trivy (pinned image), from its docker archive or,
# for an image already in the registry, by digest.
#
#   scripts/gates/sbom.sh <image.tar | registry/repository@sha256:...>...
#                         # CI: the `scan` job (service-image.yml, ci-release.yml), after image-scan.sh, one image per
#                         # job; scripts/gates/attach-sbom.sh, for an image pushed by an earlier run
#
#   docker save temporary-copy/eshop-api:local -o eshop-api.tar && scripts/gates/sbom.sh eshop-api.tar
#
# A record, not a gate: what an image contains never fails it. Not writing an SBOM does (exit 1), so the image isn't
# pushed without one. The SBOM lists packages only, no vulnerabilities (those change daily): re-scan it any time with
# `trivy sbom <name>.cdx.json`. A registry image is read for linux/arm64, the only platform built.
#
# Writes $REPORT_DIR/<name>.cdx.json (default: reports/sbom). <name> is the archive's name, or for an image.tar its
# folder's without `image-` (CI's artifact folder image-<service>/ gives <service>), or for a registry reference the
# repository's last path segment. Trivy's cache is $GATES_CACHE (default ~/.cache/eshop-gates).
set -euo pipefail

TRIVY_IMAGE=aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c

[ $# -gt 0 ] || { echo "usage: scripts/gates/sbom.sh <image.tar | registry/repository@sha256:...>..." >&2; exit 2; }

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
report_dir=$(gate_report_dir sbom)
cache=$(gate_cache trivy)

trivy() { # trivy <docker run options...> -- <trivy arguments...>
  local options=()
  while [ "$1" != -- ]; do options+=("$1"); shift; done
  shift
  docker run --rm --user "$(id -u):$(id -g)" -v "$cache:/cache" -v "$report_dir:/reports" ${options[@]+"${options[@]}"} \
    "$TRIVY_IMAGE" --cache-dir /cache --quiet "$@"
}

for image in "$@"; do
  if [[ "$image" == *@sha256:* ]]; then
    repository=${image%@*}
    name=${repository##*/}
    echo "--- $name ($image)"
    trivy -- image --platform linux/arm64 --format cyclonedx --output "/reports/$name.cdx.json" "$image"
  else
    [ -f "$image" ] || { echo "no image archive at $image" >&2; exit 2; }
    dir=$(cd "$(dirname "$image")" && pwd)
    file=$(basename "$image")
    if [ "$file" = image.tar ]; then name=$(basename "$dir"); name=${name#image-}; else name=${file%.tar}; fi
    echo "--- $name ($image)"
    trivy -v "$dir:/image:ro" -- image --input "/image/$file" --format cyclonedx --output "/reports/$name.cdx.json"
  fi
  sbom="$report_dir/$name.cdx.json"
  if ! jq -e '.bomFormat == "CycloneDX"' "$sbom" >/dev/null 2>&1; then
    echo "sbom: FAILED: no CycloneDX SBOM written for $image" >&2
    exit 1
  fi
  echo "$name: $(jq '.components | length' "$sbom") components ($sbom)"
done
echo "sbom: wrote $# SBOM(s) to $report_dir"
