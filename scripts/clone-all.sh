#!/usr/bin/env bash
# Clones the service repositories (ADR 0009: every `repository` in .github/services.json) beside this one, under the
# same parent folder, so their agent docs find ../eshop-infra and a local temporary copy builds from ../<service>
# (scripts/gates/temporary-copy.sh build). Safe to run again: a clone already there is left as it is.
#
#   scripts/clone-all.sh
#
# A repository that doesn't exist yet (not extracted) is skipped with a note. CLONE_BASE_URL (default
# https://github.com) is where repositories live: <base>/<owner>/<name>; scripts/tests/release-scripts.sh points it
# at local bare repositories.
set -euo pipefail

cd "$(dirname "$0")/.."
base=${CLONE_BASE_URL:-https://github.com}
parent=$(cd .. && pwd)

for repository in $(jq -r '[.[].repository // empty] | unique | .[]' .github/services.json); do
  name=${repository#*/}
  url="$base/$repository"
  if [ -d "$parent/$name/.git" ]; then
    echo "$name: already cloned at $parent/$name"
  elif ! GIT_TERMINAL_PROMPT=0 git ls-remote --quiet "$url" HEAD >/dev/null 2>&1; then
    echo "$name: skipped, $url doesn't exist yet"
  else
    git clone --quiet "$url" "$parent/$name"
    echo "$name: cloned to $parent/$name"
  fi
done
