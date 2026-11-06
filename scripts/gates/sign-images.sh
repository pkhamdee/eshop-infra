#!/usr/bin/env bash
# Signs the images this run pushed, keyless (ADR 0011): cosign with the run's GitHub OIDC identity, logged in Rekor.
# service-image.yml's push job runs it straight after pushing, before anything else can fail.
#
#   scripts/gates/sign-images.sh <pushed.txt>
#
# <pushed.txt>: what this run pushed, one <registry/repository>@sha256:<digest> per line (the Push step writes it
# from docker push's output). Each distinct digest is signed once. Only what this run pushed is signed, never an image
# a tag already named (scripts/gates/tags-to-push.sh skipped it, #116): vouching for whatever sits under a tag would
# vouch for an image pushed with a stolen Docker Hub token. An empty file signs nothing.
#
# The classic signature format (a sha256-<digest>.sig tag, cosign v2 without --new-bundle-format), which Sigstore's
# policy-controller verifies. Every image is tried; exit 1 if any failed, or if a line is not a digest reference (a
# tag can move, so it is never signed). Needs cosign v2 logged in to push (it reads Docker's credentials) and, in CI,
# the job's id-token: write. scripts/tests/release-scripts.sh tests it with a fake cosign.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: scripts/gates/sign-images.sh <pushed.txt>" >&2; exit 2; }
[ -f "$1" ] || { echo "no list of pushed images at $1" >&2; exit 2; }

refs=$(grep -v '^[[:space:]]*$' "$1" | sort -u || true)
if [ -z "$refs" ]; then
  echo "This run pushed no image: nothing to sign"
  exit 0
fi

failed=()
while read -r ref; do
  if [[ ! "$ref" =~ ^[a-z0-9./_-]+@sha256:[0-9a-f]{64}$ ]]; then
    echo "not a digest reference, not signed: $ref" >&2
    failed+=("$ref")
    continue
  fi
  if cosign sign --yes "$ref"; then
    echo "signed $ref"
  else
    echo "could not sign $ref" >&2
    failed+=("$ref")
  fi
done <<<"$refs"

if [ ${#failed[@]} -gt 0 ]; then
  echo "sign-images: FAILED for ${failed[*]}: those images are pushed but unsigned; a re-run can't sign them (it" \
    "pushes nothing), so the fix is a new commit (ADR 0011)" >&2
  exit 1
fi
echo "sign-images: signed $(wc -l <<<"$refs" | tr -d ' ') image(s)"
