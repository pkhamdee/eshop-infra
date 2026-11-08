# shellcheck shell=bash
# An image's signature (ADR 0011): keyless, by pkhamdee/eshop-infra's service-image.yml from main, called by the
# service's own repository. Sourced, never run: . "$(dirname "$0")/lib/signature.sh". Needs cosign (v2) and network
# access to the registry and Sigstore's public services.
#
#   signature_status <repository@digest> <source repository>   prints signed, unsigned (no signature by that
#                                                               identity), or unknown (cosign couldn't tell)
#
# Shown, never enforced, here: the cluster's ClusterImagePolicy (deploy/infrastructure/configs/image-policy.yaml)
# is what refuses an unsigned image, and also requires the source ref to be main or release/N.x.
SIGNATURE_ISSUER=https://token.actions.githubusercontent.com
SIGNATURE_IDENTITY=https://github.com/pkhamdee/eshop-infra/.github/workflows/service-image.yml@refs/heads/main

signature_status() {
  local errors
  if errors=$(cosign verify --certificate-oidc-issuer "$SIGNATURE_ISSUER" --certificate-identity "$SIGNATURE_IDENTITY" \
    --certificate-github-workflow-repository "$2" "$1" 2>&1 >/dev/null); then
    echo signed
  elif grep -qiE 'no signatures found|no matching signatures' <<<"$errors"; then
    echo unsigned
  else
    echo unknown
  fi
}
