# shellcheck shell=bash
# An image's SBOM (ADR 0010): a CycloneDX referrer of its digest in the registry, attached when the image was pushed
# (scripts/gates/attach-sbom.sh). Sourced, never run: . "$(dirname "$0")/lib/sbom.sh". Needs oras and jq.
#
#   sbom_count <repository@digest>          prints how many SBOMs the digest has; fails when the registry can't be read
#   sbom_pull <repository@digest> <file>    writes the digest's SBOM to <file>: exit 3 when it has none, 1 when it
#                                           can't be read or is not a CycloneDX SBOM
SBOM_ARTIFACT_TYPE=application/vnd.cyclonedx+json

sbom_referrers() { oras discover --artifact-type "$SBOM_ARTIFACT_TYPE" --format json "$1"; }

sbom_count() {
  local referrers
  referrers=$(sbom_referrers "$1") || return 1
  jq '.referrers | length' <<<"$referrers"
}

sbom_pull() {
  local ref=$1 out=$2 referrers sbom dir file
  referrers=$(sbom_referrers "$ref") || return 1
  sbom=$(jq -r '.referrers[0].digest // empty' <<<"$referrers")
  [ -n "$sbom" ] || return 3
  dir=$(mktemp -d)
  if oras pull --output "$dir" "${ref%@*}@$sbom" >/dev/null; then
    file=$(find "$dir" -type f -name '*.json' | head -n 1)
    if [ -n "$file" ] && jq -e '.bomFormat == "CycloneDX"' "$file" >/dev/null 2>&1; then
      mv "$file" "$out"
      rm -rf "$dir"
      return 0
    fi
  fi
  rm -rf "$dir"
  return 1
}
