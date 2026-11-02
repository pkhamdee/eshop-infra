#!/usr/bin/env bash
# Tests for e2e/run-on-actions.sh against a fake gh (records its calls, answers `run list` from fixtures) and the
# fake kubectl of e2e/check-serving.test.sh (no GitHub, no cluster needed).
#
#   e2e/run-on-actions.test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
# The fake gh: every call is appended to $FAKE/gh.log. `run list ... --jq <filter>` applies the filter to
# $FAKE/runs.json; `run watch` exits with $FAKE/watch-status (default 0).
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE/gh.log"
case "$1 $2" in
  "run list")
    while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
    jq -r "$2" "$FAKE/runs.json" ;;
  "run watch") exit "$(cat "$FAKE/watch-status" 2>/dev/null || echo 0)" ;;
esac
EOF
# The fake kubectl: `-n <ns> get <kind> [<name>] -o json` prints $FAKE/<ns>.<kind>[.<name>].json, or fails.
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
ns=$2 kind=$4 name=${5:-}
[ "$name" = "-o" ] && name=
file="$FAKE/$ns.$kind${name:+.$name}.json"
if [ -f "$file" ]; then cat "$file"; exit 0; fi
echo "Error from server (NotFound): $kind \"$name\" not found" >&2
exit 1
EOF
chmod +x "$work/bin/gh" "$work/bin/kubectl"
export PATH="$work/bin:$PATH"

failures=0
fresh() { export FAKE="$work/fake.$RANDOM$RANDOM"; mkdir -p "$FAKE"; : >"$FAKE/gh.log"; echo '[]' >"$FAKE/runs.json"; }

# Dispatched runs as `gh run list --json databaseId,createdAt,displayTitle` returns them (newest first).
runs() { # <id>=<title>[=<createdAt>]...
  printf '%s\n' "$@" | jq -R 'split("=") | {databaseId: (.[0] | tonumber), displayTitle: .[1],
    createdAt: (.[2] // "2999-01-01T00:00:00Z")}' | jq -s . >"$FAKE/runs.json"
}

# eshop-<env> fully on <version>, as e2e/check-serving.sh asks the cluster.
serving() { # <env> <version>
  jq -n --arg v "$2" '{metadata: {generation: 1}, spec: {images: [{name: "docker.io/pkhamdee/eshop-api", newTag: $v}]},
    status: {observedGeneration: 1, lastAppliedRevision: ("v" + $v + "@sha1:0123456789abcdef"),
      conditions: [{type: "Ready", status: "True", message: "Applied"}]}}' \
    >"$FAKE/flux-system.kustomization.apps-$1.json"
  jq -n --arg v "$2" '{items: [{metadata: {name: "eshop-api", generation: 1},
    spec: {replicas: 1, template: {spec: {containers: [{name: "eshop-api", image: ("docker.io/pkhamdee/eshop-api:" + $v)}]}}},
    status: {observedGeneration: 1, replicas: 1, updatedReplicas: 1, readyReplicas: 1, availableReplicas: 1}}]}' \
    >"$FAKE/eshop-$1.deployment.json"
}

fail() { echo "FAIL: ${FUNCNAME[1]}: $*" >&2; echo "    gh calls: $(paste -sd '|' "$FAKE/gh.log")" >&2; failures=$((failures + 1)); }
ok() { echo "ok: ${FUNCNAME[1]}"; }

# run <args...>: runs run-on-actions.sh, leaving its exit status in $status and output in $out.
run() { status=0; out=$("$here/run-on-actions.sh" "$@" 2>&1) || status=$?; }
called() { grep -qF -- "$1" "$FAKE/gh.log"; }

dispatches_to_the_cluster_runner_and_follows_the_run() {
  fresh; runs "42=E2E prod"
  run
  if [ "$status" -ne 0 ]; then fail "exit $status: $out"
  elif ! called "gh workflow run e2e.yml --repo pkhamdee/modernapp --ref main -f environment=prod -f version="; then fail "no dispatch"
  elif called "runner="; then fail "chose a runner; the workflow runs on eshop-e2e"
  elif ! called "gh run watch 42 --repo pkhamdee/modernapp"; then fail "did not follow run 42"
  else ok; fi
}

registers_no_runner() {
  fresh; runs "42=E2E dev"
  run dev
  if [ "$status" -ne 0 ]; then fail "exit $status: $out"
  elif called "actions/runners"; then fail "touched runner registration"
  else ok; fi
}

follows_the_run_named_after_what_it_tests() {
  fresh; runs "45=E2E dev" "44=E2E qa 0.3.0-rc.1" "43=E2E qa 0.3.0-rc.1=2000-01-01T00:00:00Z"
  serving qa 0.3.0-rc.1
  run qa 0.3.0-rc.1
  if [ "$status" -ne 0 ]; then fail "exit $status: $out"
  elif ! called "-f environment=qa -f version=0.3.0-rc.1"; then fail "did not dispatch qa 0.3.0-rc.1"
  elif ! called "gh run watch 44 "; then fail "followed the wrong run"
  elif [[ "$out" != *"actions/runs/44"* ]]; then fail "did not print the run's URL: $out"
  else ok; fi
}

stops_before_dispatching_when_the_environment_does_not_serve_the_version() {
  fresh; runs "44=E2E qa 0.3.0-rc.1"
  run qa 0.3.0-rc.1
  if [ "$status" -eq 0 ]; then fail "succeeded"
  elif called "workflow run"; then fail "dispatched anyway"
  elif [[ "$out" != *"eshop-qa is not serving 0.3.0-rc.1"* ]]; then fail "did not say why: $out"
  else ok; fi
}

qa_needs_a_version() {
  fresh
  run qa
  if [ "$status" -ne 2 ] || called "workflow run"; then fail "exit $status: $out"; else ok; fi
}

refuses_an_unknown_environment() {
  fresh
  run https://qa.eshop.localhost
  if [ "$status" -ne 2 ] || called "workflow run"; then fail "exit $status: $out"; else ok; fi
}

fails_when_the_run_fails() {
  fresh; runs "42=E2E prod"; echo 1 >"$FAKE/watch-status"
  run prod
  if [ "$status" -eq 0 ]; then fail "succeeded although the run failed"; else ok; fi
}

dispatches_to_the_cluster_runner_and_follows_the_run
registers_no_runner
follows_the_run_named_after_what_it_tests
stops_before_dispatching_when_the_environment_does_not_serve_the_version
qa_needs_a_version
refuses_an_unknown_environment
fails_when_the_run_fails

[ "$failures" -eq 0 ] || { echo "$failures test(s) failed" >&2; exit 1; }
