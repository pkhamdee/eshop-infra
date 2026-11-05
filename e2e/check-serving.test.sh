#!/usr/bin/env bash
# Tests for e2e/check-serving.sh against a fake kubectl that answers from fixtures (no cluster needed).
#
#   e2e/check-serving.test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The fake kubectl: `-n <ns> get <kind> [<name>] -o json` prints $FAKE/<ns>.<kind>[.<name>].json, or fails like
# kubectl does for a missing object. A cluster that changes while the check waits: for the first N gets of a
# Kustomization ($FAKE/earlier/polls holds N), files in $FAKE/earlier/ take precedence.
mkdir -p "$work/bin"
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
ns=$2 kind=$4 name=${5:-}
[ "$name" = "-o" ] && name=
polls=$(cat "$FAKE/polls" 2>/dev/null || echo 0)
[ "$kind" = kustomization ] && echo $((polls += 1)) >"$FAKE/polls"
file="$FAKE/$ns.$kind${name:+.$name}.json"
if [ -f "$FAKE/earlier/polls" ] && [ "$polls" -le "$(cat "$FAKE/earlier/polls")" ] &&
  [ -f "$FAKE/earlier/${file##*/}" ]; then file="$FAKE/earlier/${file##*/}"; fi
if [ -f "$file" ]; then cat "$file"; exit 0; fi
echo "Error from server (NotFound): $kind \"$name\" not found" >&2
exit 1
EOF
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"

failures=0
fresh() { export FAKE="$work/fake.$RANDOM$RANDOM"; mkdir -p "$FAKE"; }

# A Kustomization that applied `revision`, with `images` newTags, Ready and up to date.
kustomization() { # <env> <revision> <tag> [suspend]
  jq -n --arg rev "$2" --arg tag "$3" --argjson suspend "${4:-false}" '{
    metadata: {generation: 3},
    spec: {suspend: $suspend, images: [
      {name: "docker.io/pkhamdee/eshop-api", newTag: $tag},
      {name: "docker.io/pkhamdee/eshop-web", newTag: $tag}]},
    status: {observedGeneration: 3, lastAppliedRevision: $rev,
      conditions: [{type: "Ready", status: "True", observedGeneration: 3, message: ("Applied revision: " + $rev)}]}
  }' >"$FAKE/flux-system.kustomization.apps-$1.json"
}

# Deployments in eshop-<env>, each `name=image`, fully rolled out.
deployments() { # <env> <name=image>...
  local env=$1; shift
  printf '%s\n' "$@" | jq -R 'split("=") | {
    metadata: {name: .[0], generation: 2},
    spec: {replicas: 1, template: {spec: {containers: [{name: .[0], image: .[1]}]}}},
    status: {observedGeneration: 2, replicas: 1, updatedReplicas: 1, readyReplicas: 1, availableReplicas: 1}
  }' | jq -s '{items: .}' >"$FAKE/eshop-$env.deployment.json"
}

serving() { # <env> <version>: QA (or prod) fully on that version
  kustomization "$1" "v$2@sha1:0123456789abcdef0123456789abcdef01234567" "$2"
  deployments "$1" "eshop-api=docker.io/pkhamdee/eshop-api:$2" "eshop-web=docker.io/pkhamdee/eshop-web:$2"
}

# expect <refuse|serve> <message part> <args...>: runs check-serving.sh with args.
expect() {
  local want=$1 part=$2; shift 2
  local out status=0
  out=$("$here/check-serving.sh" "$@" 2>&1) || status=$?
  local got=serve; [ "$status" -eq 0 ] || got=refuse
  if [ "$got" != "$want" ] || [[ "$out" != *"$part"* ]]; then
    echo "FAIL: ${FUNCNAME[1]}: wanted $want with '$part', got $got (exit $status):" >&2
    echo "    ${out//$'\n'/$'\n    '}" >&2
    failures=$((failures + 1))
  else
    echo "ok: ${FUNCNAME[1]}"
  fi
}

refuses_when_the_environment_has_no_kustomization() {
  fresh
  expect refuse "eshop-qa is not serving 0.3.0-rc.1" qa 0.3.0-rc.1
}

serves_when_flux_applied_the_version_and_every_deployment_runs_it() {
  fresh; serving qa 0.3.0-rc.1
  expect serve "v0.3.0-rc.1@sha1:0123456789abcdef0123456789abcdef01234567" qa 0.3.0-rc.1
  expect serve "eshop-qa serves 0.3.0-rc.1" qa 0.3.0-rc.1
  expect serve "eshop-web: docker.io/pkhamdee/eshop-web:0.3.0-rc.1" qa 0.3.0-rc.1
}

refuses_when_flux_applied_another_version() {
  fresh; serving qa 0.3.0-rc.1
  kustomization qa "v0.3.0-rc.2@sha1:89abcdef0123456789abcdef0123456789abcdef" 0.3.0-rc.2
  expect refuse "apps-qa applied v0.3.0-rc.2@sha1:89abcdef" qa 0.3.0-rc.1
}

refuses_when_the_version_is_only_a_prefix_of_the_applied_one() {
  fresh; serving qa 0.3.0-rc.10
  expect refuse "applied v0.3.0-rc.10@" qa 0.3.0-rc.1
}

refuses_when_suspended() {
  fresh; serving qa 0.3.0-rc.1
  kustomization qa "v0.3.0-rc.1@sha1:0123456789abcdef0123456789abcdef01234567" 0.3.0-rc.1 true
  expect refuse "apps-qa is suspended" qa 0.3.0-rc.1
}

refuses_when_not_ready() {
  fresh; serving qa 0.3.0-rc.1
  f="$FAKE/flux-system.kustomization.apps-qa.json"
  jq '.status.conditions[0] |= (.status = "False" | .message = "health check failed")' "$f" >"$f.x" && mv "$f.x" "$f"
  expect refuse "apps-qa is not Ready: health check failed" qa 0.3.0-rc.1
}

refuses_while_flux_has_not_applied_the_latest_change() {
  fresh; serving qa 0.3.0-rc.1
  f="$FAKE/flux-system.kustomization.apps-qa.json"
  jq '.metadata.generation = 4' "$f" >"$f.x" && mv "$f.x" "$f"
  expect refuse "apps-qa has a change Flux has not applied yet" qa 0.3.0-rc.1
}

refuses_when_the_kustomization_sets_other_image_tags() {
  fresh; serving qa 0.3.0-rc.1
  f="$FAKE/flux-system.kustomization.apps-qa.json"
  jq '.spec.images[1].newTag = "0.3.0-rc.2"' "$f" >"$f.x" && mv "$f.x" "$f"
  expect refuse "apps-qa sets docker.io/pkhamdee/eshop-web:0.3.0-rc.2" qa 0.3.0-rc.1
}

refuses_when_a_deployment_runs_another_image() {
  fresh; serving qa 0.3.0-rc.1
  deployments qa "eshop-api=docker.io/pkhamdee/eshop-api:0.3.0-rc.1" "eshop-web=docker.io/pkhamdee/eshop-web:0.2.0"
  expect refuse "eshop-web runs docker.io/pkhamdee/eshop-web:0.2.0" qa 0.3.0-rc.1
}

ignores_images_that_are_not_eshop_releases() {
  fresh; serving qa 0.3.0-rc.1
  deployments qa "eshop-api=docker.io/pkhamdee/eshop-api:0.3.0-rc.1" "proxy=docker.io/library/busybox:1.37"
  expect serve "apps-qa applied v0.3.0-rc.1@" qa 0.3.0-rc.1
}

refuses_while_a_deployment_is_rolling_out() {
  fresh; serving qa 0.3.0-rc.1
  f="$FAKE/eshop-qa.deployment.json"
  jq '.items[0].status |= (.replicas = 2 | .updatedReplicas = 1)' "$f" >"$f.x" && mv "$f.x" "$f"
  expect refuse "eshop-api has not finished rolling out" qa 0.3.0-rc.1
}

refuses_while_a_deployment_is_not_ready() {
  fresh; serving qa 0.3.0-rc.1
  f="$FAKE/eshop-qa.deployment.json"
  jq '.items[1].status |= (.readyReplicas = 0 | .availableReplicas = 0)' "$f" >"$f.x" && mv "$f.x" "$f"
  expect refuse "eshop-web has not finished rolling out" qa 0.3.0-rc.1
}

refuses_when_there_are_no_deployments() {
  fresh; serving qa 0.3.0-rc.1
  echo '{"items": []}' >"$FAKE/eshop-qa.deployment.json"
  expect refuse "no Deployments in eshop-qa" qa 0.3.0-rc.1
}

refuses_an_image_whose_tag_only_starts_with_the_version() {
  fresh; serving qa 0.3.0-rc.1
  deployments qa "eshop-api=docker.io/pkhamdee/eshop-api:0.3.0-rc.10"
  expect refuse "eshop-api runs docker.io/pkhamdee/eshop-api:0.3.0-rc.10" qa 0.3.0-rc.1
}

accepts_an_image_pinned_by_digest_too() {
  fresh; serving qa 0.3.0-rc.1
  deployments qa "eshop-api=docker.io/pkhamdee/eshop-api:0.3.0-rc.1@sha256:abc123"
  expect serve "apps-qa applied v0.3.0-rc.1@" qa 0.3.0-rc.1
}

qa_takes_only_a_release_candidate() {
  fresh; serving qa 0.3.0
  expect refuse "qa takes a release candidate X.Y.Z-rc.N" qa 0.3.0
  expect refuse "qa takes a release candidate X.Y.Z-rc.N" qa v0.3.0-rc.1
  expect refuse "qa takes a release candidate X.Y.Z-rc.N" qa
}

prod_takes_only_a_release() {
  fresh; serving prod 0.2.0
  expect serve "apps-prod applied v0.2.0@" prod 0.2.0
  expect refuse "prod takes a release X.Y.Z" prod 0.3.0-rc.1
}

# Dev follows main: Flux applied main at a commit, with the images that revision pins (no spec.images).
dev_at() { # <commit>
  kustomization dev "main@sha1:$1" unused
  f="$FAKE/flux-system.kustomization.apps-dev.json"
  jq 'del(.spec.images)' "$f" >"$f.x" && mv "$f.x" "$f"
  deployments dev "eshop-api=docker.io/pkhamdee/eshop-api:main-44296ee-1793488244" \
    "eshop-web=docker.io/pkhamdee/eshop-web:main-44296ee-1793488244"
}
commit=ee5d66335285f4a9e8ddd3727847f1f9a8b5ee00
older=0dac0f7a1b2c3d4e5f60718293a4b5c6d7e8f901

serves_dev_at_the_main_commit_flux_applied() {
  fresh; dev_at "$commit"
  expect serve "eshop-dev serves main at $commit" dev "$commit"
  expect serve "apps-dev applied main@sha1:$commit" dev "$commit"
  expect serve "eshop-web: docker.io/pkhamdee/eshop-web:main-44296ee-1793488244" dev "$commit"
}

serves_dev_given_a_short_commit() {
  fresh; dev_at "$commit"
  expect serve "apps-dev applied main@sha1:$commit" dev ee5d663
}

refuses_dev_at_an_older_commit() {
  fresh; dev_at "$older"
  expect refuse "eshop-dev is not serving main at $commit: apps-dev applied main@sha1:$older" dev "$commit"
}

refuses_dev_while_pods_still_run_the_previous_images() {
  fresh; dev_at "$commit"
  f="$FAKE/eshop-dev.deployment.json"
  jq '.items[0].status |= (.replicas = 2 | .updatedReplicas = 1)' "$f" >"$f.x" && mv "$f.x" "$f"
  expect refuse "eshop-api has not finished rolling out" dev "$commit"
}

waits_until_dev_serves_the_commit() {
  fresh; dev_at "$older"
  mkdir "$FAKE/earlier" && mv "$FAKE"/*.json "$FAKE/earlier/" && echo 3 >"$FAKE/earlier/polls"
  dev_at "$commit"
  expect serve "eshop-dev serves main at $commit" --wait --timeout 60 --interval 0.1 dev "$commit"
  local polls; polls=$(cat "$FAKE/polls" 2>/dev/null || echo 0)
  [ "$polls" -eq 4 ] || { echo "FAIL: ${FUNCNAME[0]}: polled $polls times, not 4" >&2; failures=$((failures + 1)); }
}

reports_not_deployed_when_dev_never_serves_the_commit() {
  fresh; dev_at "$older"
  expect refuse "not deployed" --wait --timeout 1 --interval 0.1 dev "$commit"
  expect refuse "flux get kustomization apps-dev" --wait --timeout 1 --interval 0.1 dev "$commit"
  expect refuse "apps-dev applied main@sha1:$older" --wait --timeout 1 --interval 0.1 dev "$commit"
}

waits_for_qa_too() {
  fresh; serving qa 0.3.0-rc.1
  expect serve "eshop-qa serves 0.3.0-rc.1" --wait --timeout 1 --interval 0.1 qa 0.3.0-rc.1
  expect refuse "eshop-qa is not serving 0.3.0-rc.2: not deployed" --wait --timeout 1 --interval 0.1 qa 0.3.0-rc.2
}

does_not_wait_for_bad_arguments() {
  fresh
  expect refuse "dev takes a main commit" --wait dev 0.3.0
  expect refuse "--timeout takes seconds" --wait --timeout soon dev "$commit"
}

dev_takes_only_a_commit() {
  fresh; dev_at "$commit"
  expect refuse "dev takes a main commit" dev 0.3.0
  expect refuse "dev takes a main commit" dev ee5d6
  expect refuse "dev takes a main commit" dev
}

refuses_when_the_environment_has_no_kustomization
refuses_an_image_whose_tag_only_starts_with_the_version
accepts_an_image_pinned_by_digest_too
qa_takes_only_a_release_candidate
prod_takes_only_a_release
serves_dev_at_the_main_commit_flux_applied
serves_dev_given_a_short_commit
refuses_dev_at_an_older_commit
refuses_dev_while_pods_still_run_the_previous_images
dev_takes_only_a_commit
waits_until_dev_serves_the_commit
reports_not_deployed_when_dev_never_serves_the_commit
waits_for_qa_too
does_not_wait_for_bad_arguments
refuses_when_a_deployment_runs_another_image
ignores_images_that_are_not_eshop_releases
refuses_while_a_deployment_is_rolling_out
refuses_while_a_deployment_is_not_ready
refuses_when_there_are_no_deployments
refuses_when_suspended
refuses_when_not_ready
refuses_while_flux_has_not_applied_the_latest_change
refuses_when_the_kustomization_sets_other_image_tags
serves_when_flux_applied_the_version_and_every_deployment_runs_it
refuses_when_flux_applied_another_version
refuses_when_the_version_is_only_a_prefix_of_the_applied_one

[ "$failures" -eq 0 ] || { echo "$failures test(s) failed" >&2; exit 1; }
