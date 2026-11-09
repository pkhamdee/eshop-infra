#!/usr/bin/env bash
# Tests the cluster's image policy (deploy/infrastructure/configs/image-policy.yaml; ADR 0011, #127) with
# policy-controller's own offline tester, against real images on Docker Hub: one signed by eShop's pipeline must pass,
# an unsigned one must fail. CI's `repo rules` job runs it on every change.
#
#   scripts/check-image-policy.sh
#
# The policy is tested as if in enforce mode (a copy with `mode: enforce`): what it would refuse, whatever mode it is
# deployed in. The tester is policy-controller's `tester`, the version the cluster runs, installed by scripts/ci/tools.sh
# (pinned there with its SHA-256, and cached; Linux only, as CI). Elsewhere, point POLICY_TESTER at a tester binary for
# your platform. Needs network access to Docker Hub and Sigstore's public
# services (Fulcio, Rekor, TUF). Exit 0 when every case behaves, 1 naming the ones that don't.
set -euo pipefail

# Signed by service-image.yml from pkhamdee/thirdparty-mock's main (pkhamdee/thirdparty-mock#3), and that image's 0.6.0,
# pushed before signing started. By digest: what the tester checks never moves.
SIGNED=docker.io/pkhamdee/thirdparty-mock@sha256:eb5e800c8c1bc0183954798184eefd9f03002a59d5b6fdaac9a7439dab12609a
UNSIGNED=docker.io/pkhamdee/thirdparty-mock@sha256:4db6594816e3d99a168ad0a6256a46b49325a1e3b6b45dc05f03e8c56e609d11

cd "$(dirname "$0")/.."
policy=deploy/infrastructure/configs/image-policy.yaml

tester=${POLICY_TESTER:-}
if [ -z "$tester" ]; then
  scripts/ci/tools.sh install tester >&2
  tester="${TOOLS_CACHE:-$HOME/.cache/eshop-tools}/bin/tester"
fi

enforced=$(mktemp)
out=$(mktemp)
trap 'rm -f "$enforced" "$out"' EXIT
sed -E 's/^  mode: warn$/  mode: enforce/' "$policy" >"$enforced"
grep -q '^  mode: enforce$' "$enforced" || { echo "$policy has no top-level spec.mode to test" >&2; exit 1; }

failed=()
expect() { # expect pass|fail <image> <what>
  local result=fail
  if "$tester" -policy "$enforced" -image "$2" -log-level error >"$out" 2>&1; then result=pass; fi
  local said=passes
  [ "$result" = pass ] || said=fails
  if [ "$result" = "$1" ]; then
    echo "ok   $3: $said"
  else
    echo "FAIL $3: $said, expected to $1"
    sed 's/^/     /' "$out"
    failed+=("$3")
  fi
}
expect pass "$SIGNED" "an image signed by eShop's pipeline (thirdparty-mock, from main)"
expect fail "$UNSIGNED" "an unsigned image (thirdparty-mock 0.6.0)"

if [ ${#failed[@]} -gt 0 ]; then
  echo "image policy: FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "image policy: passed: $policy admits the signed image and refuses the unsigned one"
