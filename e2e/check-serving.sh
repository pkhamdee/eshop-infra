#!/usr/bin/env bash
# Is the environment actually serving this release (candidate), or for dev this main commit? Asks the cluster,
# not Git: the pin in clusters/local/<env>-release.yaml (dev: main) says what should run, this says what does.
#
#   e2e/check-serving.sh qa 0.3.0-rc.1      # exit 0: eshop-qa serves 0.3.0-rc.1 (prints the evidence)
#   e2e/check-serving.sh prod 0.2.0         # exit 1: not serving it, and why (stderr); exit 2: bad arguments
#   e2e/check-serving.sh dev ee5d663        # a main commit, short or full
#   e2e/check-serving.sh --wait dev ee5d663 # check every 10 s until it serves; after 15 min exit 1, "not deployed"
#                                           # (--timeout SECONDS, default 900; --interval SECONDS, default 10)
#
# Serving X means all of:
#   - Flux Kustomization apps-<env> is not suspended, has applied its latest spec, is Ready, its last applied
#     revision is the tag vX@sha1:..., and every image it sets (spec.images) has tag X;
#   - every Deployment in eshop-<env> has finished rolling out (no old pod left) and every eShop image
#     ($IMAGE_REGISTRY/..., scripts/lib/repo.sh) it runs has tag X.
# Serving main commit C (dev) means the same with revision main@sha1:C... and no tag rule: dev's tags are pinned in
# deploy/apps/dev/kustomization.yaml by Flux image automation, so they are part of that revision, and a Deployment
# that finished rolling out from it runs them.
# The e2e workflow (.github/workflows/e2e.yml) runs this before and after a test run given a version, and sign-off
# relies on that (docs/setup.md, "End-to-end smoke test"). Needs kubectl (pointed at the cluster) and jq.
# The version grammar (which environment takes which) is scripts/lib/versions.sh. Tests: e2e/check-serving.test.sh.
set -euo pipefail
# shellcheck source=../scripts/lib/versions.sh
. "$(dirname "$0")/../scripts/lib/versions.sh"
# shellcheck source=../scripts/lib/repo.sh
. "$(dirname "$0")/../scripts/lib/repo.sh"

usage() {
  echo "check-serving.sh: $*" >&2
  echo "usage: e2e/check-serving.sh [--wait [--timeout SECONDS] [--interval SECONDS]]" \
    "qa X.Y.Z-rc.N | prod X.Y.Z | dev <main commit>" >&2
  exit 2
}

wait=false timeout=900 interval=10
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) wait=true; shift ;;
    --timeout) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage "--timeout takes seconds, not '${2:-}'"; timeout=$2; shift 2 ;;
    --interval) [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage "--interval takes seconds, not '${2:-}'"; interval=$2; shift 2 ;;
    -*) usage "unknown option '$1'" ;;
    *) break ;;
  esac
done

env=${1:-}
version=${2:-}
ns=eshop-$env
# What the environment must serve: a version for QA and prod, `main at <commit>` for dev, whose applied revision
# is main@sha1:<full commit> (a short commit matches its prefix).
case "$env" in
  qa | prod)
    env_takes "$env" "$version" || usage "$env takes $(env_grammar "$env"), not '$version'"
    target=$version release=$version revision_wanted="v$version@sha1:" ;;
  dev)
    [[ "$version" =~ ^[0-9a-f]{7,40}$ ]] || usage "dev takes a main commit (7 to 40 hex digits), not '$version'"
    target="main at $version" release='' revision_wanted="main@sha1:$version" ;;
  *) usage "unknown environment '$env'" ;;
esac

refuse() { echo "$ns is not serving $target: $*" >&2; exit 1; }

# Waiting: check again every --interval until it serves, or give up after --timeout as "not deployed". Each
# reason for not serving yet is printed once, as it changes.
if $wait; then
  last=
  while :; do
    status=0
    out=$("$0" "$env" "$version" 2>&1) || status=$?
    [ "$status" -eq 0 ] && { echo "$out"; exit 0; }
    [ "$status" -eq 1 ] || { echo "$out" >&2; exit "$status"; }
    reason=${out#"$ns is not serving $target: "}
    [ "$reason" = "$last" ] || echo "waiting: $reason" >&2
    last=$reason
    [ "$SECONDS" -lt "$timeout" ] ||
      refuse "not deployed after ${timeout}s; check \`flux get kustomization apps-$env\` (last: $reason)"
    sleep "$interval"
  done
fi

err=$(mktemp)
trap 'rm -f "$err"' EXIT
kustomization=$(kubectl -n flux-system get kustomization "apps-$env" -o json 2>"$err") ||
  refuse "no Kustomization apps-$env on this cluster ($(cat "$err"))"

field() { jq -r "$@" <<<"$kustomization"; }

[ "$(field '.spec.suspend // false')" = false ] ||
  refuse "apps-$env is suspended (the environment has no release yet, or Flux was paused)"
[ "$(field '.metadata.generation')" = "$(field '.status.observedGeneration // 0')" ] ||
  refuse "apps-$env has a change Flux has not applied yet (a promotion in progress); try again once it is Ready"
ready=$(field '.status.conditions[]? | select(.type == "Ready") | "\(.status): \(.message)"')
[[ "$ready" == "True: "* ]] || refuse "apps-$env is not Ready: ${ready#*: }"
revision=$(field '.status.lastAppliedRevision // ""')
[[ "$revision" == "$revision_wanted"* ]] || refuse "apps-$env applied ${revision:-nothing yet}"
# QA and prod set every image tag to the version in spec.images; dev's tags are in the applied revision itself.
if [ -n "$release" ]; then
  # shellcheck disable=SC2016 # $v is a jq variable
  others=$(field --arg v "$release" '.spec.images[]? | select(.newTag != $v) | "\(.name):\(.newTag)"')
  [ -z "$others" ] || refuse "apps-$env sets $(paste -sd ' ' - <<<"$others")"
fi

deployments=$(kubectl -n "$ns" get deployment -o json 2>"$err") || refuse "cannot list Deployments ($(cat "$err"))"
[ "$(jq '.items | length' <<<"$deployments")" -gt 0 ] || refuse "no Deployments in $ns"
# Every eShop image ($IMAGE_REGISTRY/...) is the release's tag (QA, prod), and every Deployment has finished
# rolling out: its newest spec observed, all its pods updated and ready, and no old pod left.
problems=$(jq -r --arg v "$release" --arg registry "$IMAGE_REGISTRY/" '.items[] | .metadata.name as $d
  | ([(.spec.template.spec.initContainers // []) + .spec.template.spec.containers | .[].image
      | select($v != "" and startswith($registry)) | select(test(":" + ($v | gsub("\\."; "\\.")) + "(@|$)") | not)
      | "\($d) runs \(.)"]
    + (.status as $s | .spec.replicas as $r
      | if ($s.observedGeneration // 0) < .metadata.generation or ($s.replicas // 0) != $r
           or ($s.updatedReplicas // 0) != $r or ($s.readyReplicas // 0) != $r or ($s.availableReplicas // 0) != $r
        then ["\($d) has not finished rolling out (\($s.updatedReplicas // 0) updated, \($s.readyReplicas // 0) ready, \($s.replicas // 0) pods, \($r) wanted)"]
        else [] end))[]' <<<"$deployments")
[ -z "$problems" ] || refuse "$(paste -sd ';' - <<<"$problems" | sed 's/;/; /g')"

echo "$ns serves $target"
echo "apps-$env applied $revision"
jq -r '.items[] | .metadata.name as $d | .spec.template.spec.containers[] | "\($d): \(.image)"' <<<"$deployments"
