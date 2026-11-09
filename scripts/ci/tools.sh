#!/usr/bin/env bash
# CI's command-line tools (#158): each pinned to a version and to the SHA-256 of its download, both written here, so a
# job never trusts a checksum fetched at run time, and never needs GitHub's release downloads once its cache is warm.
# (A GitHub release-download outage blocked the v0.7.0 sign-off and, for half an hour on 2026-11-09, every PR.)
#
#   scripts/ci/tools.sh install <tool>...   puts each tool in $TOOLS_CACHE/bin and that on $GITHUB_PATH (when set);
#                                           tries every tool, then fails (exit 1) naming any it couldn't install
#   scripts/ci/tools.sh pin <tool> <version>  rewrites the tool's row below for <version>, with the checksums its
#                                           project publishes for both architectures: how a version is changed
#   scripts/ci/tools.sh list                every tool, its version and where it comes from
#
# install: a tool already in the cache with the expected checksum is used as it is; otherwise it is downloaded (curl
# retrying with backoff), checked against the SHA-256 below (a mismatch fails and installs nothing), extracted and
# cached. Workflows keep $TOOLS_CACHE (default ~/.cache/eshop-tools) in actions/cache, keyed by this file's hash: a
# new pin is a new cache. Linux on amd64 or arm64 (the runners); elsewhere, set TOOLS_ARCH.
#
# Renovate (renovate/default.json5) opens a PR when a newer version exists; it can only change the version, so the
# install then fails on the checksum, and the PR is finished by running `scripts/ci/tools.sh pin <tool> <version>`.
# scripts/tests/release-scripts.sh tests this script with a fake curl.
set -euo pipefail

# One row per tool. Columns: name, version, source (Renovate's datasource:package), the download for {arch} (amd64 or
# arm64; {xarch} is x86_64 or arm64), the file to take out of an archive ("-": the download is the binary), the
# checksums the project publishes ("-": the download's URL plus .sha256), SHA-256 for amd64, SHA-256 for arm64.
# {v} is the version.
TOOLS_TABLE=$(cat <<'TABLE'
crane    0.22.1   github-releases:google/go-containerregistry  https://github.com/google/go-containerregistry/releases/download/v{v}/go-containerregistry_Linux_{xarch}.tar.gz  crane  https://github.com/google/go-containerregistry/releases/download/v{v}/checksums.txt  0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0  898c0cff975f898a33e8c4580bdafb0e7c02c7faa33374e946762f97c4ab7110
oras     1.3.4    github-releases:oras-project/oras  https://github.com/oras-project/oras/releases/download/v{v}/oras_{v}_linux_{arch}.tar.gz  oras  https://github.com/oras-project/oras/releases/download/v{v}/oras_{v}_checksums.txt  f27adb935022d94df8dc77719c322dda592c78a0d57a6f7dcdd8d900b248c454  15702c6e3a4a56a8bd8ac5c17efdbcab56d9bada661ccbcf017f5b10c1d89399
cosign   2.6.5    github-releases:sigstore/cosign  https://github.com/sigstore/cosign/releases/download/v{v}/cosign-linux-{arch}  -  https://github.com/sigstore/cosign/releases/download/v{v}/cosign_checksums.txt  c3b4f5410e608af03a5eb0aaac84a4313d8da131248e08ff1759ac70c79d1644  426193b4c5da4d4d643e822f48fe0cc8a476ca1782a272704831f5a0cef716d7
tester   0.13.1   github-releases:sigstore/policy-controller  https://github.com/sigstore/policy-controller/releases/download/v{v}/tester-linux-{arch}  -  https://github.com/sigstore/policy-controller/releases/download/v{v}/policy-controller_checksums.txt  33ee3e1999a947697516c3cc2fe0423f82c0ceed4e0a0b7553397ebee87201bf  c18c4f39c6751b0fb45d080df17e9957741c72cad502f07fa315e98b7d04146b
gh       2.103.3  github-releases:cli/cli  https://github.com/cli/cli/releases/download/v{v}/gh_{v}_linux_{arch}.tar.gz  gh_{v}_linux_{arch}/bin/gh  https://github.com/cli/cli/releases/download/v{v}/gh_{v}_checksums.txt  4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d  ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
kubectl  1.36.2   github-releases:kubernetes/kubernetes  https://dl.k8s.io/release/v{v}/bin/linux/{arch}/kubectl  -  -  1e9045ec32bea85da43de85f0065358529ea7c7a152eca78154fba5b58c27d82  c957eb8c4bea27a3bb35b269edd9082e27f027f7b76b20b5bf4afebc726c6d3e
TABLE
)
# Notes on the pins: cosign stays on v2 (ADR 0011: v3's bundle format isn't verified by policy-controller yet).
# tester is policy-controller's offline tester (scripts/check-image-policy.sh), the version the cluster runs (chart
# 0.10.8, deploy/infrastructure/controllers/policy-controller.yaml): move them together. kubectl matches k3s v1.36.

usage() {
  echo "usage: scripts/ci/tools.sh install <tool>... | pin <tool> <version> | list" >&2
  exit 2
}

row() { # row <tool>: its row, or fail
  local r
  r=$(awk -v t="$1" '$1 == t' <<<"$TOOLS_TABLE")
  [ -n "$r" ] || { echo "tools.sh: unknown tool $1 (known: $(awk '{print $1}' <<<"$TOOLS_TABLE" | paste -sd ' ' -))" >&2; exit 2; }
  echo "$r"
}

arch() {
  if [ -n "${TOOLS_ARCH:-}" ]; then echo "$TOOLS_ARCH"; return; fi
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) echo "tools.sh: no pinned tools for $(uname -m)" >&2; exit 1 ;;
  esac
}

fill() { # fill <template> <version> <arch>
  local xarch=$3
  [ "$3" = amd64 ] && xarch=x86_64
  sed -e "s/{v}/$2/g" -e "s/{arch}/$3/g" -e "s/{xarch}/$xarch/g" <<<"$1"
}

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

fetch() { # fetch <url> <file>: retries with backoff on any failure, a 5xx included
  curl --fail --silent --show-error --location --connect-timeout 20 --max-time 600 \
    --retry 6 --retry-delay 10 --retry-all-errors --output "$2" "$1"
}

install_tool() {
  local name version url member sha_amd64 sha_arm64 arch want cache dir bin download
  read -r name version _ url member _ sha_amd64 sha_arm64 <<<"$(row "$1")"
  arch=$(arch)
  want=$sha_amd64
  [ "$arch" = arm64 ] && want=$sha_arm64
  cache=${TOOLS_CACHE:-$HOME/.cache/eshop-tools}
  dir="$cache/$name-$version-$arch"
  bin="$cache/bin"
  mkdir -p "$bin"
  if [ -x "$dir/$name" ] && [ "$(cat "$dir/sha256" 2>/dev/null)" = "$want" ]; then
    echo "$name $version: from the cache"
  else
    rm -rf "$dir" && mkdir -p "$dir"
    url=$(fill "$url" "$version" "$arch")
    download="$dir/download"
    echo "$name $version: downloading $url"
    fetch "$url" "$download" || { echo "tools.sh: could not download $name $version from $url" >&2; rm -rf "$dir"; return 1; }
    if [ "$(sha256 "$download")" != "$want" ]; then
      echo "tools.sh: $name $version from $url has SHA-256 $(sha256 "$download"), not the pinned $want." \
        "A new version? Run scripts/ci/tools.sh pin $name $version" >&2
      rm -rf "$dir"
      return 1
    fi
    if [ "$member" = - ]; then
      mv "$download" "$dir/$name"
    else
      tar -xzf "$download" -C "$dir" "$(fill "$member" "$version" "$arch")"
      mv "$dir/$(fill "$member" "$version" "$arch")" "$dir/$name.bin" && rm -rf "${dir:?}/$(fill "$member" "$version" "$arch" | cut -d/ -f1)" "$download"
      mv "$dir/$name.bin" "$dir/$name"
    fi
    chmod 0755 "$dir/$name"
    echo "$want" >"$dir/sha256"
  fi
  ln -sf "$dir/$name" "$bin/$name"
}

install() {
  [ $# -gt 0 ] || usage
  local tool failed=() bin="${TOOLS_CACHE:-$HOME/.cache/eshop-tools}/bin"
  for tool in "$@"; do row "$tool" >/dev/null; done # an unknown tool fails before anything is downloaded
  for tool in "$@"; do install_tool "$tool" || failed+=("$tool"); done
  if [ -n "${GITHUB_PATH:-}" ]; then echo "$bin" >>"$GITHUB_PATH"; fi
  if [ ${#failed[@]} -gt 0 ]; then
    echo "tools: FAILED: ${failed[*]} not installed (the others are, in $bin)" >&2
    exit 1
  fi
  echo "tools: $* in $bin"
}

pin() {
  [ $# -eq 2 ] || usage
  local name=$1 version=${2#v} source url member sums old new a file sha sha_amd64="" sha_arm64="" self listing
  read -r name _ source url member sums _ _ <<<"$(row "$1")"
  listing=$(mktemp) && trap 'rm -f "$listing"' RETURN
  for a in amd64 arm64; do
    file=$(fill "$url" "$version" "$a")
    if [ "$sums" = - ]; then
      fetch "$file.sha256" "$listing"
      sha=$(tr -d ' \n' <"$listing")
    else
      fetch "$(fill "$sums" "$version" "$a")" "$listing"
      sha=$(awk -v f="${file##*/}" '$2 == f || $2 == "*" f { print $1 }' "$listing")
    fi
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "tools.sh: no published SHA-256 for ${file##*/}" >&2; exit 1; }
    if [ "$a" = amd64 ]; then sha_amd64=$sha; else sha_arm64=$sha; fi
  done
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  old=$(row "$name")
  new="$(printf '%-8s %-8s %s  %s  %s  %s  %s  %s' "$name" "$version" "$source" "$url" "$member" "$sums" "$sha_amd64" "$sha_arm64")"
  awk -v o="$old" -v n="$new" '$0 == o { print n; next } { print }' "$self" >"$self.new" && cat "$self.new" >"$self" && rm "$self.new"
  echo "pinned $name $version (amd64 $sha_amd64, arm64 $sha_arm64)"
}

case "${1:-}" in
  install) shift; install "$@" ;;
  pin) shift; pin "$@" ;;
  list) awk '{ printf "%-8s %-9s %s\n", $1, $2, $3 }' <<<"$TOOLS_TABLE" ;;
  *) usage ;;
esac
