#!/usr/bin/env bash
# Pin check (#149): what the pipeline runs and builds from never moves under it. Fails (exit 1), listing each one,
# on:
#   - a workflow's `uses:` not pinned by a 40-character commit SHA. Excepted: local actions (./...) and eShop's own
#     reusable workflow pkhamdee/eshop-infra/.github/workflows/service-image.yml@main, whose ref is part of the
#     identity the cluster's image policy trusts (ADR 0011);
#   - a Dockerfile `FROM` without a digest (image:tag@sha256:...). Excepted: an earlier stage of the same file, scratch;
#   - a chart version that floats (1.2.x, *, ^1.2, ~1.2, >=1) under deploy/ or clusters/;
#   - a workflow job that runs on a runner (runs-on) without timeout-minutes (#152): a stuck job holds its runner
#     for GitHub's default of 6 hours.
# Renovate keeps the pins current (renovate/default.json); this check keeps new ones pinned.
#
#   scripts/gates/pins.sh                              # this repository (CI: the `repo rules` job)
#   GATES_SOURCE=../eshop-web scripts/gates/pins.sh    # a service repository (service-image.yml's `sast` job)
#
# Needs only bash, find and grep. scripts/tests/release-scripts.sh tests it.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$GATES_SOURCE"

found=()
note() { found+=("$1"); }

# --- Actions ---
if [ -d .github ]; then
  while IFS= read -r file; do
    while IFS= read -r hit; do
      line=${hit%%:*}
      ref=$(sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*["'"'"']?([^"'"'"'[:space:]]+).*/\1/' <<<"${hit#*:}")
      case "$ref" in
        ./*) continue ;;
        pkhamdee/eshop-infra/.github/workflows/service-image.yml@main) continue ;;
      esac
      [[ "$ref" =~ @[0-9a-f]{40}$ ]] || note "$file:$line: action not pinned by commit SHA: $ref"
    done < <(grep -nE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]' "$file" || true)
  done < <(find .github -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
fi

# --- Job timeouts ---
if [ -d .github/workflows ]; then
  while IFS= read -r file; do
    while IFS= read -r hit; do note "$file: $hit"; done < <(awk '
      /^jobs:/ { injobs = 1; next }
      injobs && /^[^ #]/ { injobs = 0 }
      function flush() { if (job != "" && runs && !timeout) print "job " job " (line " line ") has runs-on but no timeout-minutes" }
      injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); job = $1; sub(":", "", job); line = NR; runs = 0; timeout = 0; next }
      injobs && /^    runs-on:/ { runs = 1 }
      injobs && /^    timeout-minutes:/ { timeout = 1 }
      END { flush() }' "$file")
  done < <(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
fi

# --- Dockerfiles ---
while IFS= read -r file; do
  stages=" scratch "
  while IFS= read -r hit; do
    line=${hit%%:*}
    # FROM [--platform=...] image [AS name]
    read -r -a words <<<"$(sed -E 's/^[[:space:]]*FROM[[:space:]]+//I; s/--[a-z]+=[^[:space:]]+[[:space:]]+//g' <<<"${hit#*:}")"
    image=${words[0]:-}
    if [ "${#words[@]}" -ge 3 ] && [[ "${words[1]}" =~ ^[Aa][Ss]$ ]]; then alias=$(tr '[:upper:]' '[:lower:]' <<<"${words[2]}"); else alias=""; fi
    lower=$(tr '[:upper:]' '[:lower:]' <<<"$image")
    if [[ "$stages" != *" $lower "* ]] && [[ "$image" != *@sha256:* ]]; then
      note "$file:$line: base image without a digest: $image"
    fi
    [ -z "$alias" ] || stages+="$alias "
  done < <(grep -niE '^[[:space:]]*FROM[[:space:]]' "$file" || true)
done < <(find . \( -name node_modules -o -name .git \) -prune -o -type f \( -name Dockerfile -o -name 'Dockerfile.*' -o -name '*.Dockerfile' \) -print | sort)

# --- Chart versions ---
for dir in deploy clusters; do
  [ -d "$dir" ] || continue
  while IFS= read -r hit; do
    note "$hit: chart version floats"
  done < <(grep -rnE '^[[:space:]]+version:[[:space:]]*"?([~^<>*]|[0-9v][^"[:space:]]*\.(x|X|\*)"?([[:space:]]|$))' "$dir" \
    --include='*.yaml' --include='*.yml' | grep -v 'gotk-components.yaml' || true)
done

if [ ${#found[@]} -gt 0 ]; then
  printf '%s\n' "${found[@]}"
  echo "pins: FAILED: ${#found[@]} problem(s) above. Pin actions by commit SHA (# vX.Y.Z comment), images by digest" \
    "(tag@sha256:...) and charts to an exact version (Renovate keeps them current); give every job timeout-minutes." >&2
  exit 1
fi
echo "pins: passed: every action, base image and chart version is pinned, and every job has a timeout"
