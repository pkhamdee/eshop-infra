#!/usr/bin/env bash
# SAST gate: Semgrep CE over the repo's own code, with a pinned engine and a pinned ruleset.
#
#   scripts/gates/sast.sh          # needs docker and git; CI runs it in the `sast` job (ci-release.yml)
#   GATES_SOURCE=../eshop-web scripts/gates/sast.sh   # a service repository's code (service-image.yml)
#
# Fails (exit 1) on any ERROR-severity finding that is not accepted in scripts/gates/sast-accepted.txt (with
# GATES_SOURCE: that repository's own sast-accepted.txt at its root, if it has one; paths relative to its root).
# WARNING and INFO findings are reported but never fail. Inline `nosemgrep` comments are ignored on purpose:
# the accepted file, where every entry needs a reason, is the only way to accept a finding.
#
# Reports go to $REPORT_DIR (default: reports/sast): semgrep.json (every finding), semgrep.sarif, summary.txt.
# Rules are the semgrep-rules repository at a pinned commit, cached in $GATES_CACHE (default ~/.cache/eshop-gates).
set -euo pipefail

SEMGREP_IMAGE=semgrep/semgrep:1.183.0@sha256:2e45517a85e13a9cca14a2a00df6bb48affd66b8ebfae1b0991cd57578362fb0
RULES_REPO=https://github.com/semgrep/semgrep-rules.git
RULES_COMMIT=9bbf021d0acffa3095fcffd17b2bc7787eb4796d # 2026-10-08
# Rule folders of semgrep-rules that match what this repo contains.
RULE_SETS=(csharp typescript javascript dockerfile bash yaml/github-actions html)
# The repo's own code and configuration; .agents/.claude hold third-party agent skills. A service repository
# (GATES_SOURCE) is scanned whole, but for those, through its .semgrepignore (service-image.yml copies this one's).
TARGETS=(services e2e scripts .github deploy clusters)

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
report_dir=$(gate_report_dir sast)
cache=$(gate_cache "") # the cache itself: the rules are one folder per commit in it
repo=$GATES_SOURCE
accepted=/gates/scripts/gates/sast-accepted.txt
if [ "$repo" != "$GATES_ROOT" ]; then
  TARGETS=(.)
  accepted=/dev/null
  [ ! -f "$repo/sast-accepted.txt" ] || accepted=/src/sast-accepted.txt
fi
cd "$repo"
rules="$cache/semgrep-rules-$RULES_COMMIT"

if [ ! -d "$rules" ]; then
  # Fetched by commit, so git verifies the content; moved into place only when complete.
  tmp=$(mktemp -d "$cache/semgrep-rules.XXXXXX")
  git init -q "$tmp"
  git -C "$tmp" fetch -q --depth 1 "$RULES_REPO" "$RULES_COMMIT"
  git -C "$tmp" checkout -q FETCH_HEAD
  mv "$tmp" "$rules"
fi

configs=()
for set in "${RULE_SETS[@]}"; do configs+=(--config "/rules/$set"); done

# Exit code 0 even with findings: the decision is made below, against the accepted findings. --no-git-ignore:
# git inside the container trips over the mount's owner and over worktrees; .semgrepignore lists what to skip.
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e SEMGREP_SEND_METRICS=off \
  -v "$repo:/src:ro" -v "$rules:/rules:ro" -v "$report_dir:/reports" -w /src \
  "$SEMGREP_IMAGE" semgrep scan --metrics=off --disable-version-check --disable-nosem --no-git-ignore --quiet \
  "${configs[@]}" \
  --json-output=/reports/semgrep.json --sarif-output=/reports/semgrep.sarif \
  "${TARGETS[@]}" >/dev/null

docker run --rm --user "$(id -u):$(id -g)" \
  -v "$repo:/src:ro" -v "$GATES_ROOT:/gates:ro" -v "$report_dir:/reports" -w /src \
  --entrypoint python3 "$SEMGREP_IMAGE" -I /gates/scripts/gates/sast-verdict.py \
  /reports/semgrep.json "$accepted" /reports/summary.txt
