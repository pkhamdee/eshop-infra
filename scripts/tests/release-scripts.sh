#!/usr/bin/env bash
# Tests for the release scripts, run against throwaway Git repos (a bare "origin" and clones of it), never GitHub:
#   scripts/release.sh             cuts release-candidate tags
#   scripts/check-release-tag.sh   CI's decision on a pushed v* tag
#   scripts/promotion-pr.sh        the promotion PR's branch, pin commit and body
#   scripts/sign-off-pr.sh         the sign-off PR: opened on QA's pass, closed when stale
#   scripts/gate-reports.sh        each candidate image's CI run and its Locust and ZAP reports
#   scripts/sign-off.sh            the merged sign-off PR: its refusals, the release (its SBOMs), re-runs
#   scripts/check-new-images.sh    CI's push job: a version's images are never overwritten
#   scripts/smoke-targets.sh       the smoke test's targets: what a push to main (promotions and rollbacks
#                                  included), or a dispatch, tests where
#   scripts/deployment.sh          the smoke test's Deployments: create, in progress, outcome, superseded, replaced
#   scripts/notify.sh              the smoke test's email: who gets which result, the subject and body, the rollback
#   scripts/protect-main.sh        main's ruleset, the tag rulesets and the release and smoke-test environments,
#                                  and each service repository's ruleset, publish environment and issues (dry run
#                                  and apply)
#   scripts/clone-all.sh           clones the service repositories beside this one
#   scripts/gates/tags-to-push.sh, attach-sbom.sh, sign-images.sh   the image push jobs: never an existing tag;
#                                  each image's SBOM; signing only what was pushed
# `gh`, `crane`, `oras`, `cosign` and `curl` are fakes on PATH that record their arguments and keep GitHub's and the registry's state in files.
# Run from anywhere: scripts/tests/release-scripts.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# As in e2e.yml on main: scripts/deployment.sh records Deployments only from a run on main, and which run attempt.
export GITHUB_REF=refs/heads/main GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1

# Fake gh: logs every call and keeps GitHub's state (Releases, PRs) as files in $GH_STATE.
#   run list   (release.sh): prints a run URL
#   api .../rulesets, .../deployment-branch-policies: print $FAKE_RULESETS, $FAKE_BRANCH_POLICIES (GitHub's JSON;
#              FAKE_NO_ENVIRONMENT=1: the environment doesn't exist, 404); api <path> --method <M>: a write, its
#              body kept as $GH_STATE/api-<M>-<path with / as _>
#   api .../deployments[?environment=&ref=&sha=], .../deployments/<id>[/statuses]: GitHub's Deployments as files in
#              $GH_STATE/deployments, <id>.json (the create body plus its id, numbered from 1, and created_at: now,
#              or $FAKE_NOW) and <id>.statuses (one status body per line, oldest first); create (--method POST) and
#              list newest first, --jq applied (strings printed raw, as gh does)
#   api .../commits/<sha>/pulls, .../pulls/<n>, .../actions/runs/<id>/artifacts: $FAKE_COMMIT_PULLS, $FAKE_PULL,
#              $FAKE_ARTIFACTS (GitHub's JSON), --jq applied
#              (a run with $GH_STATE/artifacts-<id>.json lists that instead)
#   api repos/<owner>/<repo>/actions/runs?head_sha=<sha>, .../actions/runs/<id>/jobs: a commit's runs and a run's jobs,
#              from $GH_STATE/runs-<owner>_<repo>-<sha>.json and jobs-<id>.json (ci_run writes them); FAKE_RUNS_ERROR=1
#              makes listing runs fail
#   api .../actions/runs/<id>/attempts/<n>: {status} from $GH_STATE/run-<id>-<n> (default completed)
#   api .../collaborators/<login>/permission: {role_name} from $FAKE_ROLES (login=role,...; 404 for anyone else)
#   api repos/<owner>/<repo>/contents/<path>: the file $FAKE_CONTENTS/<owner>/<repo>/contents/<path> (404 without it)
#   (only the calls these scripts make; gh's own --jq is not emulated beyond that)
#   release view/create/edit/upload, pr list/create/edit/close: against $GH_STATE (a Release's notes and assets, an open PR's body as
#              pr-<head with / as _>; pr list without --head lists them as {headRefName, url}, --jq applied; a closed
#              one becomes closed-pr-<head>, its comment comment-<head>)
mkdir -p "$work/bin" "$work/gh-state"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
arg() { local name=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$name" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "run list") echo "https://github.com/test/run/1" ;;
  "api "*)
    deployments="$GH_STATE/deployments" query=${2#*\?}; path=${2%%\?*}; jq_filter=$(arg --jq "$@"); jq_filter=${jq_filter:-.}
    if [[ "$path" == */deployments && " $* " == *" --method POST "* ]]; then # create: the next id, the body kept
      mkdir -p "$deployments"; id=$(( $(find "$deployments" -name '*.json' | wc -l) + 1 ))
      jq --argjson id "$id" --arg at "${FAKE_NOW:-}" '. + {id: $id, created_at: (if $at != "" then $at else now | todate end)}' \
        >"$deployments/$id.json"; jq -r "$jq_filter" "$deployments/$id.json"
    elif [[ "$path" =~ /deployments/([0-9]+)/statuses$ && " $* " == *" --method POST "* ]]; then # appended, oldest first
      [ -f "$deployments/${BASH_REMATCH[1]}.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      jq -c . >>"$deployments/${BASH_REMATCH[1]}.statuses"; echo '{}'
    elif [[ "$path" == */deployments ]]; then # list, newest first, filtered by ?environment=, ?ref= and ?sha=
      env=$(sed -nE 's/(^|.*&)environment=([^&]*).*/\2/p' <<<"$query"); ref=$(sed -nE 's/(^|.*&)ref=([^&]*).*/\2/p' <<<"$query")
      sha=$(sed -nE 's/(^|.*&)sha=([^&]*).*/\2/p' <<<"$query") # GitHub's .sha is the ref's commit: these refs are SHAs
      find "$deployments" -name '*.json' -exec cat {} + 2>/dev/null | jq -s --arg env "$env" --arg ref "$ref" --arg sha "$sha" \
        'map(select(($env == "" or .environment == $env) and ($ref == "" or .ref == $ref) and ($sha == "" or .ref == $sha)))
         | sort_by(-.id)' \
        | jq -r "$jq_filter"
    elif [[ "$path" =~ /deployments/([0-9]+)$ ]]; then # one Deployment
      [ -f "$deployments/${BASH_REMATCH[1]}.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      jq -r "$jq_filter" "$deployments/${BASH_REMATCH[1]}.json"
    elif [[ "$path" =~ /deployments/([0-9]+)/statuses$ ]]; then # newest first
      cat "$deployments/${BASH_REMATCH[1]}.statuses" 2>/dev/null | jq -s 'reverse' | jq -r "$jq_filter"
    elif [[ "$path" =~ /commits/[0-9a-f]+/pulls$ ]]; then jq -r "$jq_filter" <<<"${FAKE_COMMIT_PULLS:-[]}"
    elif [[ "$path" =~ /pulls/[0-9]+$ ]]; then jq -r "$jq_filter" <<<"${FAKE_PULL:-null}"
    elif [[ "$path" =~ ^repos/([^/]+)/([^/]+)/actions/runs$ ]]; then # a commit's runs (?head_sha=), as ci_run wrote them
      [ -z "${FAKE_RUNS_ERROR:-}" ] || { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
      sha=$(sed -nE 's/(^|.*&)head_sha=([^&]*).*/\2/p' <<<"$query")
      { cat "$GH_STATE/runs-${BASH_REMATCH[1]}_${BASH_REMATCH[2]}-$sha.json" 2>/dev/null || echo '{"workflow_runs":[]}'; } \
        | jq -r "$jq_filter"
    elif [[ "$path" =~ /actions/runs/([0-9]+)/jobs$ ]]; then
      { cat "$GH_STATE/jobs-${BASH_REMATCH[1]}.json" 2>/dev/null || echo '{"jobs":[]}'; } | jq -r "$jq_filter"
    elif [[ "$path" =~ /actions/runs/([0-9]+)/artifacts$ ]]; then # a run's own (ci_run), else $FAKE_ARTIFACTS
      if [ -f "$GH_STATE/artifacts-${BASH_REMATCH[1]}.json" ]; then jq -r "$jq_filter" "$GH_STATE/artifacts-${BASH_REMATCH[1]}.json"
      else jq -r "$jq_filter" <<<"${FAKE_ARTIFACTS:-[]}"; fi
    elif [[ "$path" =~ /actions/runs/([0-9]+)/attempts/([0-9]+)$ ]]; then # its status: $GH_STATE/run-<id>-<attempt>
      status=$(cat "$GH_STATE/run-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}" 2>/dev/null || echo completed)
      jq -n --arg s "$status" '{status: $s}' | jq -r "$jq_filter"
    elif [[ "$path" =~ /collaborators/([^/]+)/permission$ ]]; then # FAKE_ROLES: login=role,... (GitHub's role_name)
      role=$(tr ',' '\n' <<<"${FAKE_ROLES:-}" | sed -n "s/^${BASH_REMATCH[1]}=//p")
      [ -n "$role" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      jq -n --arg r "$role" '{role_name: $r}' | jq -r "$jq_filter"
    elif [[ "$path" == repos/*/contents/* ]]; then # a file of a repository's default branch, raw
      cat "${FAKE_CONTENTS:-/nonexistent}/${path#repos/}" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    elif [[ " $* " == *" --method "* ]]; then # a write: its JSON body (stdin) kept as $GH_STATE/api-<METHOD>-<path>
      method=$(arg --method "$@"); path=${2//\//_}
      if [[ " $* " == *" --input - "* ]]; then cat >"$GH_STATE/api-$method-$path"; else : >"$GH_STATE/api-$method-$path"; fi
      echo '{}'
    elif [[ "$2" == */rulesets ]]; then echo "${FAKE_RULESETS:-[]}"
    elif [[ "$2" == */deployment-branch-policies ]]; then
      [ -z "${FAKE_NO_ENVIRONMENT:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      none='{"total_count":0,"branch_policies":[]}'; echo "${FAKE_BRANCH_POLICIES:-$none}"
    fi ;;
  "release view") [ -f "$GH_STATE/release-$3" ] || { echo "release not found" >&2; exit 1; }
    echo "https://github.com/test/releases/tag/$3" ;;
  "release create") cp "$(arg --notes-file "$@")" "$GH_STATE/release-$3"; echo "https://github.com/test/releases/tag/$3" ;;
  "release edit") cp "$(arg --notes-file "$@")" "$GH_STATE/release-$3" ;;
  "release upload") [ -f "$GH_STATE/release-$3" ] || { echo "release not found" >&2; exit 1; } # its assets: release-<tag>-assets/
    mkdir -p "$GH_STATE/release-$3-assets"
    for f in "$@"; do [ -f "$f" ] && cp "$f" "$GH_STATE/release-$3-assets/"; done; true ;;
  "pr list") head=$(arg --head "$@")
    if [ -n "$head" ]; then [ ! -f "$GH_STATE/pr-${head//\//_}" ] || echo "https://github.com/test/pull/1"
    else # every open PR, its head from the file name (the heads used here have one /), --jq applied
      for f in "$GH_STATE"/pr-*; do
        [ ! -f "$f" ] || { h=${f##*/pr-}; jq -n --arg h "${h/_//}" '{headRefName: $h, url: "https://github.com/test/pull/\($h)"}'; }
      done | jq -s . | jq -r "$(arg --jq "$@")"
    fi ;;
  "pr create") head=$(arg --head "$@"); cp "$(arg --body-file "$@")" "$GH_STATE/pr-${head//\//_}"
    echo "https://github.com/test/pull/1" ;;
  "pr edit") ;;
  "pr close") mv "$GH_STATE/pr-${3//\//_}" "$GH_STATE/closed-pr-${3//\//_}"; arg --comment "$@" >"$GH_STATE/comment-${3//\//_}" ;;
esac
GH

# Fake crane: a registry kept as files, $REGISTRY/<repository>/<tag> holding the digest; logs every call.
# FAKE_CRANE_FAIL_COPY=<repository> makes copying into that repository fail (a sign-off interrupted half-way);
# FAKE_CRANE_LS_ERROR=1 makes listing tags fail as a registry error would.
cat >"$work/bin/crane" <<'CRANE'
#!/usr/bin/env bash
echo "crane $*" >>"$CRANE_LOG"
resolve() { # resolve <repo:tag | repo@digest>: prints the digest, or fails as for a missing manifest
  if [[ "$1" == *@* ]]; then
    grep -rqx -- "${1#*@}" "$REGISTRY/${1%@*}" 2>/dev/null && { echo "${1#*@}"; return; }
  else
    cat "$REGISTRY/${1%:*}/${1##*:}" 2>/dev/null && return
  fi
  echo "MANIFEST_UNKNOWN: $1" >&2; return 1
}
case "$1" in
  digest) resolve "$2" ;;
  ls) [ -z "${FAKE_CRANE_LS_ERROR:-}" ] || { echo "GET https://index.docker.io/v2/: TOOMANYREQUESTS" >&2; exit 1; }
    [ -d "$REGISTRY/$2" ] || { echo "NAME_UNKNOWN: $2" >&2; exit 1; }; ls "$REGISTRY/$2" ;;
  config) digest=$(resolve "$2") || exit 1 # labels: the revision in $REGISTRY/.revision/<digest>, when there is one
    revision=$(cat "$REGISTRY/.revision/$digest" 2>/dev/null || true)
    jq -n --arg r "$revision" 'if $r == "" then {config: {}} else {config: {Labels: {"org.opencontainers.image.revision": $r}}} end' ;;
  copy) digest=$(resolve "$2") || exit 1
    [ "${3%:*}" != "${FAKE_CRANE_FAIL_COPY:-}" ] || { echo "copy to $3 failed" >&2; exit 1; }
    mkdir -p "$REGISTRY/${3%:*}" && echo "$digest" >"$REGISTRY/${3%:*}/${3##*:}" ;;
  *) echo "fake crane: unexpected $*" >&2; exit 1 ;;
esac
CRANE
# Fake oras: a digest's SBOMs (ADR 0010) are the files in $REGISTRY/.referrers/<digest>/, named by the attached file's
# title; discover lists each as digest sbom/<digest>/<title>, which pull fetches. FAKE_ORAS_DISCOVER_ERROR=1: discover
# fails; FAKE_ORAS_ATTACH_ERROR=1: attach fails.
cat >"$work/bin/oras" <<'ORAS'
#!/usr/bin/env bash
echo "oras $*" >>"$ORAS_LOG"
arg() { local name=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$name" ] && { echo "$2"; return; }; shift; done; }
ref=${*: -1}
case "$1" in
  discover) [ -z "${FAKE_ORAS_DISCOVER_ERROR:-}" ] || { echo "Error: TOOMANYREQUESTS" >&2; exit 1; }
    subject=${ref#*@} dir="$REGISTRY/.referrers/${ref#*@}"
    { [ -d "$dir" ] && ls "$dir"; true; } | jq -R . \
      | jq -s --arg s "$subject" '{referrers: map({digest: "sbom/\($s)/\(.)", annotations: {"org.opencontainers.image.title": .}})}' ;;
  pull) sbom=${ref##*@sbom/}
    [ -f "$REGISTRY/.referrers/$sbom" ] || { echo "Error: $ref: not found" >&2; exit 1; }
    cp "$REGISTRY/.referrers/$sbom" "$(arg --output "$@")/" ;;
  attach) [ -z "${FAKE_ORAS_ATTACH_ERROR:-}" ] || { echo "Error: denied" >&2; exit 1; }
    subject=${*: -2:1} file=${ref%:*}
    [ -f "$file" ] || { echo "Error: no file $file" >&2; exit 1; }
    mkdir -p "$REGISTRY/.referrers/${subject#*@}" && cp "$file" "$REGISTRY/.referrers/${subject#*@}/$file" ;;
  *) echo "fake oras: unexpected $*" >&2; exit 1 ;;
esac
ORAS
# Fake cosign: `sign` logs its call; FAKE_COSIGN_FAIL=<ref>: signing that ref fails. `verify <repository@digest>`
# passes when $REGISTRY/.signatures/<digest> names the repository given with --certificate-github-workflow-repository
# (the source repository the pipeline signed it from), else fails as cosign does: no signature, or none matching.
# FAKE_COSIGN_VERIFY_ERROR=1: verify fails as when Sigstore can't be reached.
cat >"$work/bin/cosign" <<'COSIGN'
#!/usr/bin/env bash
echo "cosign $*" >>"$COSIGN_LOG"
arg() { local name=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$name" ] && { echo "$2"; return; }; shift; done; }
ref=${*: -1}
case "$1" in
  sign) [ "$ref" != "${FAKE_COSIGN_FAIL:-}" ] || { echo "Error: signing $ref: fulcio unavailable" >&2; exit 1; } ;;
  verify) [ -z "${FAKE_COSIGN_VERIFY_ERROR:-}" ] || { echo "Error: getting TUF root: connection refused" >&2; exit 1; }
    signed="$REGISTRY/.signatures/${ref#*@}"
    [ -f "$signed" ] || { echo "Error: no signatures found" >&2; exit 1; }
    [ "$(cat "$signed")" = "$(arg --certificate-github-workflow-repository "$@")" ] \
      || { echo "Error: no matching signatures: certificate extensions" >&2; exit 1; }
    echo '[{"critical":{}}]' ;;
  *) echo "fake cosign: unexpected $*" >&2; exit 1 ;;
esac
COSIGN
chmod +x "$work/bin/gh" "$work/bin/crane" "$work/bin/oras" "$work/bin/cosign"
export PATH="$work/bin:$PATH" GH_LOG="$work/gh.log" GH_STATE="$work/gh-state" CRANE_LOG="$work/crane.log" ORAS_LOG="$work/oras.log"
export COSIGN_LOG="$work/cosign.log"

# A service's fake digest (sha256 and 64 hex digits), the same at every version; and every service's image at a
# version, one per line (<name>:<version>@<digest>), as CI and sign-off list them: images_at <version> [registry]
services=$(jq -r '.[].service' "$root/.github/services.json")
fake_digest() { echo "sha256:$(echo "$1" | git hash-object --stdin)$(echo "x$1" | git hash-object --stdin | cut -c1-24)"; }
images_at() { local svc; for svc in $services; do echo "${2:-docker.io/pkhamdee}/$svc:$1@$(fake_digest "$svc")"; done; }
# pin-release.sh <env> <version> in $clone with every service's fake digest (PIN_IMAGES), as a promotion pins it.
pin_in_clone() { (cd "$clone" && PIN_IMAGES=$(images_at "$2") scripts/pin-release.sh "$1" "$2" >/dev/null 2>&1); }

# This checkout's clusters/local with the pins as they were before QA's first release candidate (prod on 0.2.0,
# apps-qa suspended), whatever main pins now: promotions change the live pins, and the tests must not change with them.
clusters="$work/clusters"
cp -R "$root/clusters/local" "$clusters"
for env in qa prod; do
  PIN_DIR=$clusters PIN_IMAGES=$(images_at 0.2.0) "$root/scripts/pin-release.sh" "$env" 0.2.0 >/dev/null
done
if ! grep -q ' # release-pin-until: qa$' "$clusters/qa-release.yaml"; then
  awk '{ print } /^  name: apps-qa$/ { found = 1 } found && /^spec:$/ { print "  suspend: true # release-pin-until: qa"; found = 0 }' \
    "$clusters/qa-release.yaml" >"$clusters/qa-release.yaml.pins" && mv "$clusters/qa-release.yaml.pins" "$clusters/qa-release.yaml"
fi

failures=0
check() { # check <description> <command...>: passes when the command succeeds
  local what=$1; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; sed 's/^/     /' "$work/out" 2>/dev/null; failures=$((failures + 1)); fi
}

# A fresh origin with one commit on main holding this checkout's scripts and $clusters; prints a clone's path.
fresh() {
  local dir="$work/$1"
  git init -q --bare -b main "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
  mkdir -p "$dir/seed/clusters" "$dir/seed/.github"
  cp -R "$root/scripts" "$dir/seed/"
  cp "$root/.github/services.json" "$dir/seed/.github/"
  cp -R "$clusters" "$dir/seed/clusters/local"
  git -C "$dir/seed" add -A
  git -C "$dir/seed" commit -qm "initial"
  git -C "$dir/seed" push -q origin main
  git clone -q "$dir/origin.git" "$dir/clone"
  echo "$dir/clone"
}
origin() { git -C "$clone/../origin.git" "$@"; }

# release.sh <args> in $clone, answering the confirmation with $answer (default y; answer=none gives no input at
# all, stdin closed). Output in $work/out.
release() {
  if [ "${answer:-}" = none ]; then (cd "$clone" && scripts/release.sh "$@" </dev/null) >"$work/out" 2>&1
  else (cd "$clone" && printf '%s\n' "${answer:-y}" | scripts/release.sh "$@") >"$work/out" 2>&1; fi
}

# --- scripts/release.sh ---

# Dev's smoke test of origin/main's commit, recorded as e2e.yml does (scripts/deployment.sh): dev_tested <state>
# [description] makes a Deployment in progress and, unless <state> is in_progress, finishes it with <state>.
# Every fresh origin starts with the same "initial" commit, so each test starts from no Deployments at all.
smoke_run=https://github.com/test/actions/runs/42
dev_tested() {
  local sha id
  sha=$(origin rev-parse refs/heads/main)
  id=$(cd "$clone" && scripts/deployment.sh start dev "$sha" "$smoke_run" https://eshop.localhost)
  [ "$1" = in_progress ] \
    || (cd "$clone" && scripts/deployment.sh finish "$id" "$1" "$smoke_run" https://eshop.localhost ${2:+"$2"})
}
no_deployments() { rm -rf "$GH_STATE/deployments"; }
# recorded_off_main <env> <ref> <state>: a Deployment that a copy of e2e.yml run from another branch recorded, written
# straight to the (fake) API since deployment.sh refuses to: it must never count as evidence.
recorded_off_main() {
  local id
  id=$(jq -n --arg env "$1" --arg ref "$2" '{ref: $ref, environment: $env, auto_merge: false, required_contexts: [],
        payload: {workflow_ref: "refs/heads/feature", run_url: "https://github.com/test/actions/runs/66"}}' \
    | gh api repos/pkhamdee/eshop-infra/deployments --method POST --input - --jq .id)
  jq -n --arg state "$3" '{state: $state, log_url: "https://github.com/test/actions/runs/66"}' \
    | gh api "repos/pkhamdee/eshop-infra/deployments/$id/statuses" --method POST --input - >/dev/null
}

rc_on_new_series() {
  no_deployments
  dev_tested success
  release 0.3.0-rc.1 \
    && [ "$(origin cat-file -t refs/tags/v0.3.0-rc.1)" = tag ] \
    && [ "$(origin rev-parse 'refs/tags/v0.3.0-rc.1^{commit}')" = "$(origin rev-parse refs/heads/release/0.x)" ] \
    && [ "$(origin rev-parse refs/heads/release/0.x)" = "$(origin rev-parse refs/heads/main)" ]
}
clone=$(fresh rc-new-series)
check "release.sh X.Y.Z-rc.N pushes an annotated vX.Y.Z-rc.N tag on a new release/N.x forked from main" rc_on_new_series

# Tags exist on origin now; a refused run must leave origin's refs exactly as they were.
refs_before() { origin for-each-ref --format='%(refname) %(objectname)' >"$work/refs"; }
refs_unchanged() { origin for-each-ref --format='%(refname) %(objectname)' | diff -q - "$work/refs" >/dev/null; }
refused() { # refused <expected message part> <release.sh args...>
  local expected=$1; shift
  refs_before
  ! release "$@" && grep -qF -- "$expected" "$work/out" && refs_unchanged
}

next_rc_on_existing_branch() {
  # A fix lands on release/0.x after rc.1 (and main moves on): rc.2 tags the branch head, not main.
  git -C "$clone" checkout -q -b fix origin/release/0.x
  git -C "$clone" commit -q --allow-empty -m "fix"
  git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
  git -C "$clone" commit -q --allow-empty -m "feature on main"
  git -C "$clone" push -q origin HEAD:refs/heads/main --force
  release 0.3.0-rc.2 \
    && [ "$(origin rev-parse 'refs/tags/v0.3.0-rc.2^{commit}')" = "$(origin rev-parse refs/heads/release/0.x)" ] \
    && [ "$(origin log -1 --format=%s 'refs/tags/v0.3.0-rc.2^{commit}')" = fix ]
}
check "release.sh tags the head of an existing release/N.x" next_rc_on_existing_branch
check "release.sh refuses plain X.Y.Z and points to sign-off" \
  refused 'merging its sign-off PR "Sign off v0.3.0-rc.N" tags v0.3.0' 0.3.0
check "release.sh refuses a malformed version" refused 'usage: scripts/release.sh [--force] X.Y.Z-rc.N' 0.3.0-rc
check "release.sh refuses a dry-run version (dispatched, never tagged)" \
  refused 'usage: scripts/release.sh [--force] X.Y.Z-rc.N' 0.0.0-test.1
check "release.sh refuses an existing candidate tag" refused 'v0.3.0-rc.1 already exists' 0.3.0-rc.1
released_version_refused() {
  git -C "$clone" tag -a v0.3.0 -m "Release 0.3.0" origin/release/0.x
  git -C "$clone" push -q origin refs/tags/v0.3.0
  refused 'v0.3.0 is already released' 0.3.0-rc.3
}
check "release.sh refuses a candidate for a released version" released_version_refused
answer=n check "release.sh pushes nothing when not confirmed" refused 'aborted' 0.3.1-rc.1
answer=none check "release.sh with no input (stdin closed) says why and pushes nothing" \
  refused 'no answer to "Push?" (no input): run scripts/release.sh in a terminal' 0.3.1-rc.1

# The first candidate of a new minor (X.Y.0-rc.1) on an existing release/N.x must carry main's work: release.sh
# merges origin/main in first (a merge commit whose tree is main's), as v0.2.0 was made by hand (f613dcb).
commit_file() { # commit_file <file> <subject>: a commit in $clone changing <file>
  echo "$2" >>"$clone/$1"; git -C "$clone" add "$1"; git -C "$clone" commit -qm "$2"
}
clone=$(fresh new-minor)
git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
git -C "$clone" checkout -q -b rel origin/release/0.x
commit_file old-fix.txt "old fix, on release/0.x only"          # superseded by the next merge from main, like #39
git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
git -C "$clone" checkout -q main
commit_file feature-a.txt "feature a"
git -C "$clone" push -q origin HEAD:main
git -C "$clone" checkout -q rel
git -C "$clone" fetch -q origin
merge=$(git -C "$clone" commit-tree 'origin/main^{tree}' -p HEAD -p origin/main -m "Merge main into release/0.x for v0.2.0")
git -C "$clone" reset -q --hard "$merge"
git -C "$clone" tag -a v0.2.0 -m "Release 0.2.0"
commit_file fix.txt "fix on release/0.x and main"
git -C "$clone" push -q origin HEAD:refs/heads/release/0.x refs/tags/v0.2.0
git -C "$clone" checkout -q main
git -C "$clone" cherry-pick -x rel >/dev/null
commit_file feature-b.txt "feature b"
git -C "$clone" push -q origin HEAD:main
no_deployments
dev_tested failure "eshop-dev is not serving main: not deployed after 900s"
check "release.sh X.Y.0-rc.1 merging main refuses when dev's Deployment of main's commit failed" \
  refused "failed: eshop-dev is not serving main: not deployed after 900s ($smoke_run)" 0.3.0-rc.1
dev_tested success
answer=n check "release.sh X.Y.0-rc.1 on an existing release/N.x pushes nothing when not confirmed" \
  refused 'aborted' 0.3.0-rc.1
new_minor_merges_main() {
  local old_head
  old_head=$(origin rev-parse refs/heads/release/0.x)
  release 0.3.0-rc.1 || return 1
  local tagged
  tagged=$(origin rev-parse 'refs/tags/v0.3.0-rc.1^{commit}')
  [ "$tagged" = "$(origin rev-parse refs/heads/release/0.x)" ] \
    && [ "$(origin rev-parse "$tagged^1")" = "$old_head" ] \
    && [ "$(origin rev-parse "$tagged^2")" = "$(origin rev-parse refs/heads/main)" ] \
    && [ "$(origin rev-parse "$tagged^{tree}")" = "$(origin rev-parse 'refs/heads/main^{tree}')" ] \
    && [ "$(origin log -1 --format=%s "$tagged")" = "Merge main into release/0.x for v0.3.0-rc.1" ] \
    && grep -qF 'merge origin/main into release/0.x' "$work/out"
}
check "release.sh X.Y.0-rc.1 on an existing release/N.x merges origin/main in (main's tree) and tags the merge" \
  new_minor_merges_main
patch_rc_tags_head() {
  # It brings in nothing from main, so dev's Deployments don't matter: main's latest failed.
  dev_tested failure
  release 0.2.1-rc.1 \
    && [ "$(origin rev-parse 'refs/tags/v0.2.1-rc.1^{commit}')" = "$(origin rev-parse refs/heads/release/0.x)" ] \
    && [ "$(origin rev-parse 'refs/tags/v0.2.1-rc.1^{commit}')" = "$(origin rev-parse 'refs/tags/v0.3.0-rc.1^{commit}')" ]
}
check "release.sh X.Y.Z-rc.1 with Z > 0 tags the branch head (merges nothing), whatever dev's Deployments" \
  patch_rc_tags_head

clone=$(fresh new-minor-unmerged-fix)
git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
git -C "$clone" checkout -q -b rel origin/release/0.x
commit_file fix.txt "fix only on release/0.x"
git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
git -C "$clone" checkout -q main
commit_file feature.txt "feature"
git -C "$clone" push -q origin HEAD:main
unmerged_fix_refused() {
  refused 'not on main' 0.3.0-rc.1 && grep -qF 'fix only on release/0.x' "$work/out"
}
check "release.sh X.Y.0-rc.1 refuses while release/N.x has a commit that is not on main (git cherry)" \
  unmerged_fix_refused

# A candidate that brings in origin/main (a new release/N.x, or X.Y.0-rc.1 merging main) needs dev's latest
# Deployment of exactly that main commit to have succeeded (ADR 0008).
clone=$(fresh dev-guard)
no_deployment_refused() {
  no_deployments
  refused "dev has no Deployment of main at $(origin rev-parse --short refs/heads/main)" 0.3.0-rc.1
}
check "release.sh refuses a candidate bringing in main when dev has no Deployment of that commit" no_deployment_refused
older_commit_passed_refused() { # a success for main's previous commit says nothing about this one
  no_deployments
  dev_tested success
  git -C "$clone" commit -q --allow-empty -m "feature"
  git -C "$clone" push -q origin HEAD:main
  refused "dev has no Deployment of main at $(origin rev-parse --short refs/heads/main)" 0.3.0-rc.1
}
check "release.sh checks dev's Deployment of exactly origin/main's commit" older_commit_passed_refused
off_main_pass_refused() { # a pass recorded by a run from another branch, and a failure on main since: not evidence
  no_deployments
  recorded_off_main dev "$(origin rev-parse refs/heads/main)" success
  refused "dev has no Deployment of main at $(origin rev-parse --short refs/heads/main)" 0.3.0-rc.1 || return 1
  dev_tested failure && recorded_off_main dev "$(origin rev-parse refs/heads/main)" success
  refused "dev's smoke test of main at $(origin rev-parse --short refs/heads/main) failed" 0.3.0-rc.1
}
check "release.sh counts only dev's Deployments recorded by a run on main" off_main_pass_refused
running_refused() {
  no_deployments
  dev_tested in_progress
  refused 'still running (in_progress): wait for it to finish' 0.3.0-rc.1 && grep -qF "$smoke_run" "$work/out"
}
check "release.sh refuses while dev's smoke test of main's commit is still running" running_refused
failed_refused() {
  no_deployments
  dev_tested failure "2 of 9 smoke tests failed"
  refused "failed: 2 of 9 smoke tests failed ($smoke_run)" 0.3.0-rc.1
}
check "release.sh refuses when dev's latest Deployment of main's commit failed, saying why and linking the run" \
  failed_refused
retried_and_passed() { # the latest Deployment counts: an earlier failure of the same commit, then a pass
  no_deployments
  dev_tested failure
  dev_tested success
  answer=n refused 'aborted' 0.3.0-rc.1
}
check "release.sh goes by dev's latest Deployment of main's commit" retried_and_passed
superseded_refused() {
  no_deployments
  dev_tested inactive superseded
  refused 'inactive (superseded)' 0.3.0-rc.1
}
check "release.sh refuses when dev's Deployment of main's commit is inactive (superseded)" superseded_refused
forced() {
  no_deployments
  dev_tested failure
  release --force 0.3.0-rc.1 || return 1
  [ "$(origin rev-parse 'refs/tags/v0.3.0-rc.1^{commit}')" = "$(origin rev-parse refs/heads/main)" ] \
    && origin cat-file tag refs/tags/v0.3.0-rc.1 \
      | grep -qF "Cut with --force: dev's Deployment of $(origin rev-parse refs/heads/main) was failure ($smoke_run)."
}
check "release.sh --force cuts it anyway and the tag message records dev's Deployment state" forced

clone=$(fresh skip-ci)
git -C "$clone" commit -q --allow-empty -m "eshop-dev: update images [skip ci]"
git -C "$clone" push -q origin HEAD:main
check "release.sh refuses a commit with a skip-ci marker" refused 'skip-ci marker' 0.3.0-rc.1
no_deployments

# --- scripts/check-release-tag.sh (CI's plan job, in a full clone with the tag fetched) ---

clone=$(fresh tags)
git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
git -C "$clone" fetch -q origin
git -C "$clone" tag -a v0.3.0-rc.1 -m "Release candidate 0.3.0-rc.1"
git -C "$clone" tag -a v0.3.0 -m "Release 0.3.0"
git -C "$clone" tag v0.3.0-rc.2                             # lightweight
git -C "$clone" tag -a v0.3.0-beta.1 -m "not a candidate"
git -C "$clone" commit -q --allow-empty -m "on main only"
git -C "$clone" tag -a v0.4.0-rc.1 -m "Release candidate 0.4.0-rc.1"
tag_check() { (cd "$clone" && scripts/check-release-tag.sh "$1") >"$work/out" 2>"$work/err"; }
builds() { tag_check "$1" && [ "$(cat "$work/out")" = "$2" ]; }
skipped() { tag_check "$1" && [ ! -s "$work/out" ] && grep -qF 'a merged sign-off PR' "$work/err"; }
rejected() { ! tag_check "$1" && grep -qF -- "$2" "$work/err"; }

check "check-release-tag.sh builds an annotated candidate on release/N.x as X.Y.Z-rc.N" builds v0.3.0-rc.1 0.3.0-rc.1
check "check-release-tag.sh skips a plain vX.Y.Z (sign-off made it; not built)" skipped v0.3.0
check "check-release-tag.sh rejects a lightweight candidate" rejected v0.3.0-rc.2 lightweight
check "check-release-tag.sh rejects a tag that is neither" rejected v0.3.0-beta.1 'not vX.Y.Z-rc.N'
check "check-release-tag.sh rejects a candidate on no release/N.x branch" rejected v0.4.0-rc.1 'release/N.x'

# --- scripts/candidate-images.sh (CI's plan job: copy each candidate image by digest, or build it at the tag) ---

clone=$(fresh candidates)
export REGISTRY="$work/candidates/registry"
cand_services="eshop-api eshop-web thirdparty-mock eshop-node-api eshop-sync-master"
put_image() { mkdir -p "$REGISTRY/docker.io/pkhamdee/$1" && echo "$3" >"$REGISTRY/docker.io/pkhamdee/$1/$2"; }
dev_pins() { # dev_pins <tag> [service to leave out]: dev's and thirdparty's pins as Flux image automation writes them
  local svc
  mkdir -p "$clone/deploy/apps/dev" "$clone/deploy/thirdparty"
  : >"$clone/deploy/apps/dev/kustomization.yaml"
  : >"$clone/deploy/thirdparty/kustomization.yaml"
  for svc in $cand_services; do
    [ "$svc" != "${2:-}" ] || continue
    if [ "$svc" = thirdparty-mock ]; then
      printf "  - name: docker.io/pkhamdee/%s\n    newTag: %s # {\"\$imagepolicy\": \"thirdparty:%s:tag\"}\n" "$svc" "$1" "$svc" \
        >>"$clone/deploy/thirdparty/kustomization.yaml"
    else
      printf "  - name: docker.io/pkhamdee/%s\n    newTag: %s # {\"\$imagepolicy\": \"eshop-dev:%s:tag\"}\n" "$svc" "$1" "$svc" \
        >>"$clone/deploy/apps/dev/kustomization.yaml"
    fi
  done
  git -C "$clone" add deploy && git -C "$clone" commit -qm "dev: images $1" && git -C "$clone" push -q origin HEAD:main
}
candidate() { (cd "$clone" && git fetch -q --tags origin && scripts/candidate-images.sh "$1") >"$work/out" 2>&1; }
copies() { # copies <service> <digest>: the candidate copies <service> from that digest
  jq -e --arg s "$1" --arg i "docker.io/pkhamdee/$1@$2" '.copy | any(.service == $s and .image == $i)' "$work/out" >/dev/null
}
builds_nothing() { [ "$(jq '.build | length' "$work/out")" = 0 ]; } # every service is built in its own repository
copies_all_from() { # copies_all_from <digest prefix>: builds nothing and copies every service from <prefix>-<service>
  local svc
  builds_nothing && for svc in $cand_services; do copies "$svc" "sha256:$1-$svc" || return 1; done
}

for svc in $cand_services; do put_image "$svc" main-aaaaaaa-100 "sha256:dev1-$svc"; done
dev_pins main-aaaaaaa-100
git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
git -C "$clone" tag -a v0.5.0-rc.1 -m "Release candidate 0.5.0-rc.1" && git -C "$clone" push -q origin refs/tags/v0.5.0-rc.1
new_branch_copies_dev() { candidate v0.5.0-rc.1 && copies_all_from dev1 && grep -qF 'dev pins of main' "$work/out"; }
check "candidate-images.sh: a candidate on a main commit (new release/N.x) copies every image dev's pins name" \
  new_branch_copies_dev

# main moves on; X.Y.0-rc.1 on the existing branch is release.sh's merge (main's tree, parents: branch head, main).
for svc in $cand_services; do put_image "$svc" main-bbbbbbb-200 "sha256:dev2-$svc"; done
dev_pins main-bbbbbbb-200
main_commit=$(git -C "$clone" rev-parse HEAD)
merge=$(git -C "$clone" commit-tree "$main_commit^{tree}" -p origin/release/0.x -p "$main_commit" -m "Merge main into release/0.x for v0.6.0-rc.1")
git -C "$clone" push -q origin "$merge:refs/heads/release/0.x"
git -C "$clone" tag -a v0.6.0-rc.1 -m "Release candidate 0.6.0-rc.1" "$merge" && git -C "$clone" push -q origin refs/tags/v0.6.0-rc.1
merge_copies_dev() { candidate v0.6.0-rc.1 && copies_all_from dev2; }
check "candidate-images.sh: release.sh's merge of main copies the images main's dev pins name (not the branch's)" \
  merge_copies_dev

# A patch on the branch head (rc.2, after rc.1): every service is in its own repository, so nothing is built here.
# A service's newest release-0.x-<sha>-<ts> image made after the previous tag (<ts> later than the tag) is swapped
# in; an older one belongs to an earlier minor's patches and is ignored; the others are copied from rc.1.
for svc in $cand_services; do put_image "$svc" 0.6.0-rc.1 "sha256:rc1-$svc"; done
git -C "$clone" checkout -q -b fix origin/release/0.x
git -C "$clone" commit -q --allow-empty -m "patch: eshop-api" && git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
git -C "$clone" tag -a v0.6.0-rc.2 -m "Release candidate 0.6.0-rc.2" && git -C "$clone" push -q origin refs/tags/v0.6.0-rc.2
put_image eshop-api release-0.x-1111111-100 sha256:old-patch-api            # before rc.1: an earlier minor's
put_image eshop-api release-0.x-2222222-9999999998 sha256:patch-api
put_image eshop-api release-0.x-3333333-9999999999 sha256:newer-patch-api   # the newest: this one
put_image eshop-sync-master release-0.x-3333333-9999999999 sha256:patch-sync
put_image eshop-web release-1.x-4444444-9999999999 sha256:other-line-web    # another release line: ignored
put_image eshop-node-api release-0.x-5555555-100 sha256:old-patch-node      # only an old one: copied from rc.1
patch_swaps_newest() {
  candidate v0.6.0-rc.2 && builds_nothing \
    && copies eshop-api sha256:newer-patch-api && copies eshop-sync-master sha256:patch-sync \
    && copies eshop-web sha256:rc1-eshop-web && copies eshop-node-api sha256:rc1-eshop-node-api \
    && copies thirdparty-mock sha256:rc1-thirdparty-mock \
    && jq -e '.source | contains("patched with eshop-api:release-0.x-3333333-9999999999")' "$work/out" >/dev/null
}
check "candidate-images.sh: a patch candidate swaps in each service's newest release-N.x image made since the previous tag, and copies the rest from it" \
  patch_swaps_newest

# With no patch image since, a candidate on the branch head copies every image of the previous one.
for svc in $cand_services; do put_image "$svc" 0.6.0-rc.2 "sha256:rc2-$svc"; done
rm -f "$REGISTRY"/docker.io/pkhamdee/*/release-*  # the patches above are in rc.2 now
put_image eshop-api release-0.x-3333333-200 sha256:patch-before-rc2
git -C "$clone" commit -q --allow-empty -m "docs only" && git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
git -C "$clone" tag -a v0.6.0-rc.3 -m "Release candidate 0.6.0-rc.3" && git -C "$clone" push -q origin refs/tags/v0.6.0-rc.3
no_patch_copies_previous() { candidate v0.6.0-rc.3 && copies_all_from rc2; }
check "candidate-images.sh: with no patch image made since the previous tag, a branch-head candidate copies all of its images" \
  no_patch_copies_previous
unreadable_registry_refused() {
  ! FAKE_CRANE_LS_ERROR=1 candidate v0.6.0-rc.3 && grep -qF "could not list the tags of docker.io/pkhamdee/eshop-api" "$work/out"
}
check "candidate-images.sh refuses a branch-head candidate when the registry's tags can't be read" unreadable_registry_refused

# What it can't resolve, it refuses: nothing untested is filled in.
git -C "$clone" checkout -q main && git -C "$clone" pull -q --ff-only origin main
dev_pins main-bbbbbbb-200 thirdparty-mock
git -C "$clone" tag -a v0.7.0-rc.1 -m "Release candidate 0.7.0-rc.1" && git -C "$clone" push -q origin refs/tags/v0.7.0-rc.1
missing_pin_refused() { ! candidate v0.7.0-rc.1 && grep -qF 'pins no image of thirdparty-mock' "$work/out"; }
check "candidate-images.sh refuses when main pins no image of a service" missing_pin_refused
dev_pins main-ccccccc-300
git -C "$clone" tag -a v0.8.0-rc.1 -m "Release candidate 0.8.0-rc.1" && git -C "$clone" push -q origin refs/tags/v0.8.0-rc.1
# shellcheck disable=SC2317 # run through check, which ShellCheck can't follow here
missing_image_refused() { ! candidate v0.8.0-rc.1 && grep -qF 'eshop-api:main-ccccccc-300 is missing' "$work/out"; }
check "candidate-images.sh refuses when a pinned image is missing from the registry" missing_image_refused

# --- scripts/pin-release.sh (the pins in clusters/local) ---

mkdir -p "$work/pins" && cp "$clusters"/*.yaml "$work/pins/"
pin() { PIN_DIR="$work/pins" "$root/scripts/pin-release.sh" "$@" >"$work/out" 2>&1; }
suspended_until_first_release() {
  # QA has no release yet in $clusters: suspended until the first candidate is pinned; prod never is.
  pin --suspended qa && ! pin --suspended prod \
    && PIN_IMAGES=$(images_at 0.3.0-rc.1) pin qa 0.3.0-rc.1 && ! pin --suspended qa && pin qa \
    && [ "$(cat "$work/out")" = 0.3.0-rc.1 ]
}
check "pin-release.sh --suspended <env> says (exit code) whether the env has no release yet; pinning one starts it" \
  suspended_until_first_release
no_pin_is_an_error() { # exit 2, not 1: "not suspended" must not be read into a missing pin
  local status=0
  pin --suspended dev || status=$?
  [ "$status" = 2 ] && grep -qF "no '# release-pin: dev' lines" "$work/out"
}
check "pin-release.sh --suspended fails (exit 2) for an env with no pin" no_pin_is_an_error
pins_state() { cat "$work/pins"/*.yaml; }
pins_digests_from_images() {
  # Each pinned image gets the digest PIN_IMAGES lists at that version (other versions' and services' lines ignored);
  # --images reads them back, and the version stays alone on its own lines.
  PIN_IMAGES="$(images_at 0.3.0-rc.2)
docker.io/pkhamdee/eshop-web:0.3.0-rc.1@sha256:$(printf 'f%.0s' $(seq 64))" pin qa 0.3.0-rc.2 || return 1
  pin --images qa && [ "$(cat "$work/out")" = "$(images_at 0.3.0-rc.2 | grep -v thirdparty-mock)" ] \
    && [ "$(grep -c '^      digest: "sha256:[0-9a-f]\{64\}" # release-pin: qa$' "$work/pins/qa-release.yaml")" -eq 4 ] \
    && [ "$(grep -c '"0.3.0-rc.2" # release-pin: qa$' "$work/pins/qa-release.yaml")" -eq 5 ] \
    && PIN_IMAGES=$(images_at 0.3.0-rc.2) pin qa 0.3.0-rc.2 && [ "$(grep -c 'digest:' "$work/pins/qa-release.yaml")" -eq 4 ]
}
check "pin-release.sh <env> <version> pins each image's digest from PIN_IMAGES beside its tag; --images reads them" \
  pins_digests_from_images
missing_digest_changes_nothing() {
  local before
  before=$(pins_state)
  ! PIN_IMAGES=$(images_at 0.3.0-rc.3 | grep -v eshop-web) pin qa 0.3.0-rc.3 \
    && grep -qF 'no digest at 0.3.0-rc.3 for: docker.io/pkhamdee/eshop-web (in PIN_IMAGES); nothing changed' "$work/out" \
    && [ "$(pins_state)" = "$before" ] \
    && ! pin qa 0.3.0-rc.3 && grep -qF 'no digests for 0.3.0-rc.3: give its images in PIN_IMAGES' "$work/out" \
    && [ "$(pins_state)" = "$before" ]
}
check "pin-release.sh refuses, changing nothing, when an image has no digest at the version (or none is given)" \
  missing_digest_changes_nothing
# shellcheck disable=SC2016 # Markdown's backticks, not expansions
rollback_pins_recorded_digests() {
  # A rollback to 0.2.0: the digests its record lists for its candidate's images (0.2.0 copies them by digest).
  local records="$work/records" before
  mkdir -p "$records"
  { printf '# Release 0.2.0\n\nCandidate: `v0.2.0-rc.3`\n\n## Images\n\n'
    images_at 0.2.0-rc.3 | sed -E 's/^(.*)$/- `\1`, built from `abc`; SBOM attached; signed/'
    echo "- \`docker.io/pkhamdee/eshop-api:0.2.0-rc.2@sha256:$(printf 'e%.0s' $(seq 64))\`, an earlier candidate"
  } >"$records/0.2.0.md"
  RELEASES_DIR=$records pin prod 0.2.0 && pin --images prod \
    && [ "$(cat "$work/out")" = "$(images_at 0.2.0 | grep -v thirdparty-mock)" ] || return 1
  before=$(pins_state)
  ! RELEASES_DIR=$records pin prod 0.1.9 && grep -qF 'or, for a release, its record releases/0.1.9.md' "$work/out" \
    && [ "$(pins_state)" = "$before" ] || return 1
  sed 's/^Candidate: .*$/Candidate: `v0.1.0-rc.1`/' "$records/0.2.0.md" >"$records/0.2.1.md"
  ! RELEASES_DIR=$records pin prod 0.2.1 && grep -qF 'names no candidate of 0.2.1' "$work/out" && [ "$(pins_state)" = "$before" ]
}
check "pin-release.sh prod X.Y.Z (a rollback) pins the digests releases/X.Y.Z.md records; refuses without a record" \
  rollback_pins_recorded_digests
reading_needs_digests() {
  local f="$work/pins/prod-release.yaml"
  cp "$f" "$work/prod-pin"
  # An image added with only its newTag line: unreadable until the next pin writes its digest.
  awk '{ print } /^  images:$/ { print "    - name: docker.io/pkhamdee/eshop-new\n      newTag: \"0.2.0\" # release-pin: prod" }' \
    "$work/prod-pin" >"$f"
  ! pin prod && grep -qF "prod pins no sha256 digest for: docker.io/pkhamdee/eshop-new" "$work/out" || return 1
  PIN_IMAGES="$(images_at 0.2.0)
docker.io/pkhamdee/eshop-new:0.2.0@$(fake_digest eshop-new)" pin prod 0.2.0 \
    && pin --images prod && grep -qxF "docker.io/pkhamdee/eshop-new:0.2.0@$(fake_digest eshop-new)" "$work/out" || return 1
  sed 's/^\(      digest: "sha256:\)[0-9a-f]*/\1abc/' "$work/prod-pin" >"$f"
  ! pin prod && grep -qF "prod pins no sha256 digest for: docker.io/pkhamdee/eshop-api" "$work/out"
  local status=$?
  cp "$work/prod-pin" "$f"
  return $status
}
check "pin-release.sh fails to read a pin with an image without a sha256 digest; pinning writes a new entry's digest" \
  reading_needs_digests

# --- scripts/promotion-pr.sh (CI's QA promotion job; sign-off's prod promotion) ---

clone=$(fresh promotion)
git -C "$clone" tag -a v0.3.0-rc.1 -m "Release candidate 0.3.0-rc.1"
git -C "$clone" push -q origin refs/tags/v0.3.0-rc.1
rc_commit=$(git -C "$clone" rev-parse 'v0.3.0-rc.1^{commit}')
git -C "$clone" commit -q --allow-empty -m "main moves on"
git -C "$clone" push -q origin HEAD:main
git -C "$clone" reset -q --hard HEAD~1                       # a stale checkout: the PR must start from origin/main
PROMOTION_IMAGES=$(images_at 0.3.0-rc.1)
export PROMOTION_IMAGES
export PROMOTION_DETAILS="### Gates
CI run: https://github.com/test/run/1"
promote() { (cd "$clone" && scripts/promotion-pr.sh "$@") >"$work/out" 2>&1; }

pin_commit_and_body() {
  : >"$GH_LOG"
  PROMOTION_PUSH=0 promote qa 0.3.0-rc.1 || return 1
  local branch=promote/qa-0.3.0-rc.1
  [ "$(git -C "$clone" rev-parse "$branch~1")" = "$(origin rev-parse main)" ] \
    && [ "$(git -C "$clone" log -1 --format=%s "$branch")" = "eshop-qa: deploy v0.3.0-rc.1" ] \
    && [ "$(git -C "$clone" diff --name-only "$branch~1" "$branch")" = clusters/local/qa-release.yaml ] \
    && (cd "$clone" && git checkout -q "$branch" && [ "$(scripts/pin-release.sh qa 2>/dev/null)" = 0.3.0-rc.1 ] \
      && [ "$(scripts/pin-release.sh --images qa)" = "$(images_at 0.3.0-rc.1 | grep -v thirdparty-mock)" ]) \
    && ! grep -q 'release-pin-until: qa$' "$clone/clusters/local/qa-release.yaml" \
    && grep -qF "docker.io/pkhamdee/eshop-web:0.3.0-rc.1@$(fake_digest eshop-web)" "$work/out" \
    && grep -qF 'CI run: https://github.com/test/run/1' "$work/out" \
    && grep -qF "$rc_commit" "$work/out" \
    && grep -qF 'https://qa.eshop.localhost' "$work/out" \
    && grep -qF 'starts eshop-qa' "$work/out" \
    && [ ! -s "$GH_LOG" ] \
    && ! origin rev-parse -q --verify refs/heads/$branch >/dev/null
}
check "promotion-pr.sh commits only the pin on a branch from origin/main and writes the PR body (no push)" \
  pin_commit_and_body

pushes_and_opens_pr() {
  git -C "$clone" checkout -q main
  : >"$GH_LOG"
  promote qa 0.3.0-rc.1 \
    && [ "$(origin log -1 --format=%s refs/heads/promote/qa-0.3.0-rc.1)" = "eshop-qa: deploy v0.3.0-rc.1" ] \
    && grep -qF 'gh pr create --base main --head promote/qa-0.3.0-rc.1 --title eshop-qa: deploy v0.3.0-rc.1' "$GH_LOG" \
    && grep -qF 'https://github.com/test/pull/1' "$work/out"
}
check "promotion-pr.sh pushes the branch and opens the PR into main" pushes_and_opens_pr

missing_tag_refused() { ! PROMOTION_PUSH=0 promote qa 0.3.0-rc.9 && grep -qF 'v0.3.0-rc.9' "$work/out"; }
check "promotion-pr.sh refuses a version with no tag" missing_tag_refused
dry_run_refused() { ! PROMOTION_PUSH=0 promote qa 0.0.0-test.1 && grep -qF 'usage: scripts/promotion-pr.sh' "$work/out"; }
check "promotion-pr.sh refuses a dry-run version" dry_run_refused
wrong_env_refused() {
  ! PROMOTION_PUSH=0 promote prod 0.3.0-rc.1 && grep -qF 'eshop-prod takes a release X.Y.Z' "$work/out" \
    && ! PROMOTION_PUSH=0 promote qa 0.3.0 && grep -qF 'eshop-qa takes a release candidate X.Y.Z-rc.N' "$work/out"
}
check "promotion-pr.sh refuses a candidate for prod and a release for QA (scripts/lib/versions.sh)" wrong_env_refused
by_hand_resolves_candidate_digests() {
  # No PROMOTION_IMAGES (a person runs it): the candidate's digests as the registry has them now, listed in the body.
  local svc
  git -C "$clone" checkout -q main
  for svc in eshop-api eshop-web eshop-node-api eshop-sync-master; do put_image "$svc" 0.3.0-rc.1 "$(fake_digest "$svc")"; done
  PROMOTION_IMAGES='' PROMOTION_PUSH=0 promote qa 0.3.0-rc.1 \
    && (cd "$clone" && [ "$(scripts/pin-release.sh --images qa)" = "$(images_at 0.3.0-rc.1 | grep -v thirdparty-mock)" ]) \
    && grep -qF -- "- \`docker.io/pkhamdee/eshop-sync-master:0.3.0-rc.1@$(fake_digest eshop-sync-master)\`" "$work/out" || return 1
  git -C "$clone" checkout -q main
  rm "$REGISTRY/docker.io/pkhamdee/eshop-web/0.3.0-rc.1"
  ! PROMOTION_IMAGES='' PROMOTION_PUSH=0 promote qa 0.3.0-rc.1 && grep -qF 'image docker.io/pkhamdee/eshop-web:0.3.0-rc.1 is missing' "$work/out"
}
check "promotion-pr.sh for a candidate without PROMOTION_IMAGES pins and lists the registry's digests (refuses a missing image)" \
  by_hand_resolves_candidate_digests
# shellcheck disable=SC2016 # Markdown's backticks, not expansions
rollback_pr_pins_recorded_digests() {
  # A rollback by hand: prod back to 0.2.5, whose record on main names its images; no PROMOTION_IMAGES.
  git -C "$clone" checkout -q -B main origin/main
  mkdir -p "$clone/releases"
  { printf '# Release 0.2.5\n\nCandidate: `v0.2.5-rc.1`\n\n## Images\n\n'
    for svc in $services; do echo "- \`docker.io/pkhamdee/$svc:0.2.5-rc.1@sha256:$(printf '%s' "$svc" | shasum -a 256 | cut -c1-64)\`"; done
  } >"$clone/releases/0.2.5.md"
  git -C "$clone" add releases && git -C "$clone" commit -qm "Sign off v0.2.5-rc.1" && git -C "$clone" push -q origin HEAD:main
  git -C "$clone" tag -a v0.2.5 -m "Release 0.2.5" && git -C "$clone" push -q origin refs/tags/v0.2.5
  PROMOTION_IMAGES='' PROMOTION_PUSH=0 promote prod 0.2.5 \
    && (cd "$clone" && scripts/pin-release.sh --images prod >"$work/pinned") \
    && [ "$(grep -c . "$work/pinned")" -eq 4 ] \
    && grep -qxF "docker.io/pkhamdee/eshop-web:0.2.5@sha256:$(printf eshop-web | shasum -a 256 | cut -c1-64)" "$work/pinned" \
    && grep -qF -- "- \`docker.io/pkhamdee/eshop-web:0.2.5@sha256:$(printf eshop-web | shasum -a 256 | cut -c1-64)\`" "$work/out"
}
check "promotion-pr.sh prod X.Y.Z without PROMOTION_IMAGES (a rollback) pins and lists the digests releases/X.Y.Z.md records" \
  rollback_pr_pins_recorded_digests

# --- scripts/sign-off-pr.sh and scripts/sign-off.sh (sign-off by PR: e2e.yml opens it, sign-off.yml acts on its merge) ---

image() { echo "$REGISTRY/docker.io/pkhamdee/$1/$2"; } # the fake registry's file for image <service> tag <tag>
sbom_file() { echo "$REGISTRY/.referrers/$(fake_digest "$1")/$1.cdx.json"; } # <service>'s candidate digest's SBOM
# <service>'s candidate digest signed by the pipeline from [repository] (default its own, .github/services.json).
sign_image() {
  mkdir -p "$REGISTRY/.signatures"
  echo "${2:-$(jq -r --arg s "$1" '.[] | select(.service == $s) | .repository' "$root/.github/services.json")}" \
    >"$REGISTRY/.signatures/$(fake_digest "$1")"
}
put_sbom() { mkdir -p "$(dirname "$(sbom_file "$1")")" && jq -n --arg s "$1" '{bomFormat: "CycloneDX", service: $s}' >"$(sbom_file "$1")"; }
# Main pins QA to 0.3.0-rc.1 in a commit made at $pinned_at (sign_off_setup); QA's smoke tests of it run after that.
pinned_at=2026-10-30T00:00:00Z
qa_run=https://github.com/test/actions/runs/7
qa_site=https://qa.eshop.localhost
# The run's Playwright report, as `gh api .../actions/runs/7/artifacts` lists it.
export FAKE_ARTIFACTS='{"artifacts":[{"id":98,"name":"playwright-report-dev"},{"id":99,"name":"playwright-report-qa"}]}'

# QA's smoke test of a candidate, recorded as e2e.yml does (scripts/deployment.sh), created now (or at $FAKE_NOW):
# qa_tested <state> [candidate, default 0.3.0-rc.1] [description]. in_progress leaves it running.
qa_tested() {
  local id
  id=$(cd "$clone" && scripts/deployment.sh start qa "v${2:-0.3.0-rc.1}" "$qa_run" "$qa_site")
  [ "$1" = in_progress ] || (cd "$clone" && scripts/deployment.sh finish "$id" "$1" "$qa_run" "$qa_site" ${3:+"$3"})
}

# A fresh origin where candidate v0.3.0-rc.1 is tagged on release/0.x, main pins QA to it (at $pinned_at), the
# registry holds its images, and QA's smoke test of it passed.
sign_off_setup() {
  clone=$(fresh "$1")
  rm -rf "${GH_STATE:?}"/*
  git -C "$clone" push -q origin HEAD:refs/heads/release/0.x
  git -C "$clone" tag -a v0.3.0-rc.1 -m "Release candidate 0.3.0-rc.1"
  git -C "$clone" push -q origin refs/tags/v0.3.0-rc.1
  rc_commit=$(git -C "$clone" rev-parse 'v0.3.0-rc.1^{commit}')
  pin_in_clone qa 0.3.0-rc.1
  GIT_COMMITTER_DATE=$pinned_at git -C "$clone" commit -qam "eshop-qa: deploy v0.3.0-rc.1"
  git -C "$clone" push -q origin HEAD:main
  export REGISTRY="$work/$1/registry"
  for svc in $services; do mkdir -p "$(dirname "$(image "$svc" x)")"; fake_digest "$svc" >"$(image "$svc" 0.3.0-rc.1)"; done
  # Every image but thirdparty-mock's carries its source commit (CI's revision label).
  mkdir -p "$REGISTRY/.revision"
  for svc in $services; do [ "$svc" = thirdparty-mock ] || echo "rev-$svc" >"$REGISTRY/.revision/$(fake_digest "$svc")"; done
  for svc in $services; do put_sbom "$svc"; done # each pushed with its SBOM (ADR 0010)
  for svc in $services; do sign_image "$svc"; done # and signed by the pipeline, from its repository (ADR 0011)
  qa_tested success
}
sign_off_pr() { (cd "$clone" && scripts/sign-off-pr.sh) >"$work/out" 2>&1; }
pin_qa() { # pin_qa <candidate>: tags it (on rc.1's commit) if needed and pins QA to it on main, as a merged promotion
  git -C "$clone" checkout -q main && git -C "$clone" pull -q --ff-only origin main
  origin rev-parse -q --verify "refs/tags/v$1" >/dev/null || {
    git -C "$clone" tag -a "v$1" -m "Release candidate $1" 'v0.3.0-rc.1^{commit}' && git -C "$clone" push -q origin "refs/tags/v$1"
  }
  pin_in_clone qa "$1"
  git -C "$clone" commit -qam "eshop-qa: deploy v$1" && git -C "$clone" push -q origin HEAD:main
}
# A service repository's CI run of a commit, as `gh api` lists it (scripts/gate-reports.sh): its push job ended
# <push>, and it kept perf-report (id <run>1) and dast-report (id <run>2) unless [artifacts JSON] says otherwise.
# ci_run <owner/repo> <sha> <run id> <created_at> <event> <push: success|skipped|failure> [artifacts JSON]
ci_run() {
  local runs="$GH_STATE/runs-${1/\//_}-$2.json"
  [ -f "$runs" ] || echo '{"workflow_runs":[]}' >"$runs"
  jq --argjson id "$3" --arg at "$4" --arg ev "$5" --arg repo "$1" \
    '.workflow_runs += [{id: $id, created_at: $at, event: $ev, html_url: "https://github.com/\($repo)/actions/runs/\($id)"}]' \
    "$runs" >"$runs.new" && mv "$runs.new" "$runs"
  jq -n --arg push "$6" '{jobs: [{name: "image / temporary copy and gates", conclusion: (if $push == "skipped" then "failure" else "success" end)},
    {name: "image / push images", conclusion: $push}]}' >"$GH_STATE/jobs-$3.json"
  if [ -n "${7:-}" ]; then echo "$7"; else
    jq -n --argjson id "$3" --arg at "$4" '{artifacts: [{id: ($id * 10 + 1), name: "perf-report", expired: false, created_at: $at},
      {id: ($id * 10 + 2), name: "dast-report", expired: false, created_at: $at}]}'
  fi >"$GH_STATE/artifacts-$3.json"
}
api_run() { echo "https://github.com/pkhamdee/eshop-api/actions/runs/$1"; } # an eshop-api run's URL, as ci_run lists it
lists_images() { # lists_images <file> <tag>: names every service's image at <tag> with its candidate's digest
  local svc
  for svc in $services; do grep -qF "docker.io/pkhamdee/$svc:$2@$(fake_digest "$svc")" "$1" || return 1; done
}

opens_sign_off_pr() {
  sign_off_setup sign-off-pr
  ci_run pkhamdee/eshop-api rev-eshop-api 500 2026-10-20T00:00:00Z push success
  : >"$GH_LOG"
  sign_off_pr || return 1
  local branch=refs/heads/sign-off/0.3.0-rc.1 record="$work/record"
  origin show "$branch:releases/0.3.0.md" >"$record" || return 1
  [ "$(origin log -1 --format=%s "$branch")" = "Sign off v0.3.0-rc.1" ] \
    && [ "$(origin rev-parse "$branch~1")" = "$(origin rev-parse refs/heads/main)" ] \
    && [ "$(origin diff --name-only "$branch~1" "$branch")" = releases/0.3.0.md ] \
    && grep -qxF "Candidate: \`v0.3.0-rc.1\`" "$record" && grep -qF "$rc_commit" "$record" \
    && lists_images "$record" 0.3.0-rc.1 \
    && grep -qF "eshop-api:0.3.0-rc.1@$(fake_digest eshop-api)\`, built from \`rev-eshop-api\`; SBOM attached" "$record" \
    && grep -qE "thirdparty-mock:0\.3\.0-rc\.1@$(fake_digest thirdparty-mock)\`; SBOM attached; signed$" "$record" \
    && grep -qxF '## Gates' "$record" \
    && grep -qF -- "- eshop-api, built from \`rev-esh\` in pkhamdee/eshop-api: [CI run]($(api_run 500)), Locust [perf-report]($(api_run 500)/artifacts/5001), ZAP [dast-report]($(api_run 500)/artifacts/5002)" "$record" \
    && grep -qF -- "- eshop-web, built from \`rev-esh\` in pkhamdee/eshop-web: no CI run of that commit pushed it" "$record" \
    && grep -qF -- '- thirdparty-mock: no source commit' "$record" \
    && grep -qF "$qa_run" "$record" && grep -qF "$qa_run/artifacts/99" "$record" && grep -qF 'Deployment 1 ' "$record" \
    && grep -qF 'gh pr create --repo pkhamdee/eshop-infra --base main --head sign-off/0.3.0-rc.1 --title Sign off v0.3.0-rc.1' "$GH_LOG" \
    && grep -qF "$qa_run/artifacts/99" "$GH_STATE/pr-sign-off_0.3.0-rc.1" \
    && grep -qF 'Sign-off PR: https://github.com/test/pull/1' "$work/out"
}
check "sign-off-pr.sh opens \"Sign off vX.Y.Z-rc.N\" when QA's Deployment of the candidate it runs succeeded, adding releases/X.Y.Z.md (candidate, digests, each image's gate reports, run, Playwright report, Deployment)" \
  opens_sign_off_pr
opens_once() { # after opens_sign_off_pr: nothing new to say, so no push and no second PR
  local head
  head=$(origin rev-parse refs/heads/sign-off/0.3.0-rc.1)
  : >"$GH_LOG"
  sign_off_pr && [ "$(origin rev-parse refs/heads/sign-off/0.3.0-rc.1)" = "$head" ] \
    && ! grep -qE '^gh pr (create|edit)' "$GH_LOG" && grep -qF 'up to date' "$work/out"
}
check "sign-off-pr.sh run again opens no second PR and pushes nothing" opens_once
flags_missing_sbom() {
  sign_off_setup sign-off-pr-sbom
  rm "$(sbom_file eshop-web)"
  sign_off_pr || return 1
  local record="$work/record"
  origin show refs/heads/sign-off/0.3.0-rc.1:releases/0.3.0.md >"$record" \
    && grep -qF "eshop-web:0.3.0-rc.1@$(fake_digest eshop-web)\`, built from \`rev-eshop-web\`; **no SBOM: sign-off will refuse it**" "$record" \
    && grep -qF "eshop-api:0.3.0-rc.1@$(fake_digest eshop-api)\`, built from \`rev-eshop-api\`; SBOM attached" "$record" || return 1
  sign_off_setup sign-off-pr-sbom-unreadable
  FAKE_ORAS_DISCOVER_ERROR=1 sign_off_pr \
    && origin show refs/heads/sign-off/0.3.0-rc.1:releases/0.3.0.md | grep -qF "SBOM not checked (the registry couldn't be read)"
}
check "sign-off-pr.sh still opens the PR when an image has no SBOM (or the registry can't be read) and says so on its line" \
  flags_missing_sbom
shows_signatures() {
  sign_off_setup sign-off-pr-signatures
  rm "$REGISTRY/.signatures/$(fake_digest eshop-web)"                # pushed before signing: unsigned
  sign_image eshop-node-api pkhamdee/eshop-web                        # signed, but from another service's repository
  : >"$COSIGN_LOG"
  sign_off_pr || return 1
  local record="$work/record"
  origin show refs/heads/sign-off/0.3.0-rc.1:releases/0.3.0.md >"$record" \
    && grep -qF "eshop-web:0.3.0-rc.1@$(fake_digest eshop-web)\`, built from \`rev-eshop-web\`; SBOM attached; **not signed**" "$record" \
    && grep -qF "eshop-node-api:0.3.0-rc.1@$(fake_digest eshop-node-api)\`, built from \`rev-eshop-node-api\`; SBOM attached; **not signed**" "$record" \
    && grep -qF "eshop-sync-master:0.3.0-rc.1@$(fake_digest eshop-sync-master)\`, built from \`rev-eshop-sync-master\`; SBOM attached; signed" "$record" \
    && grep -qF -- "--certificate-identity https://github.com/pkhamdee/eshop-infra/.github/workflows/service-image.yml@refs/heads/main --certificate-github-workflow-repository pkhamdee/eshop-api docker.io/pkhamdee/eshop-sync-master@$(fake_digest eshop-sync-master)" "$COSIGN_LOG" || return 1
  sign_off_setup sign-off-pr-signatures-unknown
  FAKE_COSIGN_VERIFY_ERROR=1 sign_off_pr \
    && origin show refs/heads/sign-off/0.3.0-rc.1:releases/0.3.0.md | grep -qF "; SBOM attached; signature not checked (cosign couldn't tell)"
}
check "sign-off-pr.sh shows each image's signature by eShop's pipeline from its own repository (signed, not signed, not checked) and opens the PR regardless" \
  shows_signatures

no_pr() { # no_pr <expected message part>: sign-off-pr.sh succeeds, opens no PR and pushes no sign-off branch
  : >"$GH_LOG"
  sign_off_pr && grep -qF -- "$1" "$work/out" && ! grep -qE '^gh pr (create|edit)' "$GH_LOG" \
    && [ -z "$(origin for-each-ref refs/heads/sign-off)" ]
}
untested_no_pr() {
  sign_off_setup sign-off-pr-untested
  no_deployments
  no_pr 'no Deployment of v0.3.0-rc.1 to qa since' || return 1
  qa_tested in_progress
  no_pr 'in_progress' || return 1
  no_deployments
  qa_tested failure "" "the Playwright demo failed"
  no_pr 'failure'
}
check "sign-off-pr.sh opens nothing while QA's Deployment of the candidate is missing, running or failed" untested_no_pr
stale_test_no_pr() { # rc.1 -> rc.2 -> rc.1: a pass from before main last pinned QA tested an earlier deployment
  sign_off_setup sign-off-pr-stale
  no_deployments
  FAKE_NOW=2026-10-29T23:00:00Z qa_tested success
  no_pr "no Deployment of v0.3.0-rc.1 to qa since eshop-qa was pinned to it ($pinned_at)"
}
check "sign-off-pr.sh ignores QA's Deployments created before main last changed QA's pin" stale_test_no_pr
released_no_pr() {
  sign_off_setup sign-off-pr-released
  git -C "$clone" tag -a v0.3.0 -m "Release 0.3.0" origin/main && git -C "$clone" push -q origin refs/tags/v0.3.0
  no_pr 'v0.3.0 is already released'
}
check "sign-off-pr.sh opens nothing for a version already released" released_no_pr

closes_on_pin_move() {
  sign_off_setup sign-off-pr-moved
  sign_off_pr || return 1
  pin_qa 0.3.0-rc.2
  : >"$GH_LOG"
  sign_off_pr && [ -f "$GH_STATE/closed-pr-sign-off_0.3.0-rc.1" ] \
    && grep -qF 'eshop-qa is pinned to 0.3.0-rc.2 on main' "$GH_STATE/comment-sign-off_0.3.0-rc.1" \
    && grep -qF 'gh pr close sign-off/0.3.0-rc.1 --repo pkhamdee/eshop-infra' "$GH_LOG" \
    && ! grep -q '^gh pr create' "$GH_LOG"
}
check "sign-off-pr.sh closes another candidate's sign-off PR, with a comment, once QA's pin moves" closes_on_pin_move
closes_on_failure() {
  sign_off_setup sign-off-pr-failed
  sign_off_pr || return 1
  qa_tested failure "" "the Playwright demo failed"
  sign_off_pr && [ -f "$GH_STATE/closed-pr-sign-off_0.3.0-rc.1" ] \
    && grep -qF "QA's latest smoke test of 0.3.0-rc.1 did not pass (failure: the Playwright demo failed)" \
      "$GH_STATE/comment-sign-off_0.3.0-rc.1" \
    && grep -qF "$qa_run" "$GH_STATE/comment-sign-off_0.3.0-rc.1"
}
check "sign-off-pr.sh closes the candidate's sign-off PR, with a comment, when QA's test of it fails" closes_on_failure
reopens_after_new_pass() { # after closes_on_failure: a new pass opens it again
  qa_tested success
  : >"$GH_LOG"
  sign_off_pr && [ -f "$GH_STATE/pr-sign-off_0.3.0-rc.1" ] && grep -q '^gh pr create' "$GH_LOG" \
    && origin show refs/heads/sign-off/0.3.0-rc.1:releases/0.3.0.md | grep -qF 'Deployment 3 '
}
check "sign-off-pr.sh opens it again on QA's next pass, with that Deployment" reopens_after_new_pass

# The sign-off PR merged into main, as GitHub's merge would (its branch was made from main, so a fast-forward), by
# qa-lead (a maintainer: repo role maintain) in PR #5; sets $before and $after, the push sign-off.yml sees.
export FAKE_COMMIT_PULLS='[{"number":5,"merged_at":"2026-10-31T00:00:00Z","html_url":"https://github.com/test/pull/5"}]'
export FAKE_PULL='{"number":5,"html_url":"https://github.com/test/pull/5","merged_by":{"login":"qa-lead"}}'
export FAKE_ROLES=qa-lead=maintain,owner=admin,tester=write
merged() {
  before=$(origin rev-parse refs/heads/main)
  origin update-ref refs/heads/main refs/heads/sign-off/0.3.0-rc.1 "$before"
  after=$(origin rev-parse refs/heads/main)
  git -C "$clone" checkout -q main && git -C "$clone" pull -q --ff-only origin main
}
sign_off() { (cd "$clone" && scripts/sign-off.sh "$before" "$after") >"$work/out" 2>&1; }
# A sign-off PR for rc.1 opened and merged.
signed_off_setup() { sign_off_setup "$1" && sign_off_pr && merged; }

# A refused sign-off changes nothing: no ref on origin, no image, no Release, no PR; and it fails, saying why.
registry_state() { (cd "$REGISTRY" && find . -type f -exec grep -H . {} + | sort); }
sign_off_refused() { # sign_off_refused <expected message part>
  refs_before; registry_state >"$work/registry"; : >"$GH_LOG"; : >"$CRANE_LOG"
  ! sign_off && grep -qF -- "Sign-off refused: $1" "$work/out" && refs_unchanged \
    && [ "$(registry_state)" = "$(cat "$work/registry")" ] \
    && ! grep -qE '^gh (release (create|edit)|pr (create|edit))' "$GH_LOG" && ! grep -q '^crane copy' "$CRANE_LOG"
}

signed_off_setup sign-off-refusals
nothing_to_sign_off() {
  local saved=$before
  before=$after; : >"$GH_LOG"
  sign_off && grep -qF 'no release record' "$work/out" && [ ! -s "$GH_LOG" ]
  local status=$?
  before=$saved
  return $status
}
check "sign-off.sh does nothing for a push that adds or changes no releases/*.md" nothing_to_sign_off
FAKE_COMMIT_PULLS='[]' check "sign-off.sh refuses a record that no merged PR brought in (who signed off is unknown)" \
  sign_off_refused "no merged pull request brought in $after"
FAKE_PULL='{"number":5,"html_url":"https://github.com/test/pull/5","merged_by":{"login":"tester"}}' \
  check "sign-off.sh refuses a sign-off PR merged by someone who is not a maintainer (role write)" \
  sign_off_refused "tester merged https://github.com/test/pull/5 but is not a maintainer of pkhamdee/eshop-infra (role: write)"
FAKE_PULL='{"number":5,"html_url":"https://github.com/test/pull/5","merged_by":{"login":"stranger"}}' \
  check "sign-off.sh refuses when the merger's role can't be read" \
  sign_off_refused "could not read stranger's role in pkhamdee/eshop-infra"

qa_moved_refused() {
  pin_qa 0.3.0-rc.2
  sign_off_refused 'eshop-qa is pinned to 0.3.0-rc.2 on main, not 0.3.0-rc.1'
  local refused=$?
  git -C "$clone" reset -q --hard HEAD~1 && git -C "$clone" push -q --force origin HEAD:main
  return $refused
}
check "sign-off.sh refuses when main pins QA to another candidate" qa_moved_refused
qa_suspended_refused() {
  # main pins QA to the candidate but suspends apps-qa again: QA runs nothing.
  sed 's/"0.2.0" # release-pin: qa$/"0.3.0-rc.1" # release-pin: qa/' "$clusters/qa-release.yaml" \
    >"$clone/clusters/local/qa-release.yaml"
  git -C "$clone" commit -qam "suspend QA" && git -C "$clone" push -q origin HEAD:main
  sign_off_refused 'eshop-qa has no release yet on main (apps-qa is suspended)'
  local refused=$?
  git -C "$clone" reset -q --hard HEAD~1 && git -C "$clone" push -q --force origin HEAD:main
  return $refused
}
check "sign-off.sh refuses while apps-qa is suspended on main" qa_suspended_refused
no_qa_deployment_refused() {
  no_deployments
  sign_off_refused "no Deployment of v0.3.0-rc.1 to qa since eshop-qa was pinned to it ($pinned_at)" \
    && grep -qF 'gh api repos/pkhamdee/eshop-infra/deployments?environment=qa&ref=v0.3.0-rc.1' "$GH_LOG" || return 1
  FAKE_NOW=2026-10-29T23:00:00Z qa_tested success # before the pin change: an earlier deployment
  sign_off_refused "no Deployment of v0.3.0-rc.1 to qa since eshop-qa was pinned to it ($pinned_at)"
}
check "sign-off.sh refuses without QA's Deployment of the candidate since main last changed QA's pin" no_qa_deployment_refused
off_main_qa_pass_refused() {
  no_deployments
  recorded_off_main qa v0.3.0-rc.1 success
  sign_off_refused "no Deployment of v0.3.0-rc.1 to qa since eshop-qa was pinned to it ($pinned_at)" || return 1
  qa_tested failure "" "the Playwright demo failed" && recorded_off_main qa v0.3.0-rc.1 success
  sign_off_refused "QA's latest Deployment of 0.3.0-rc.1 is failure"
}
check "sign-off.sh counts only QA's Deployments recorded by a run on main" off_main_qa_pass_refused
latest_failed_refused() {
  qa_tested success && qa_tested failure "" "the Playwright demo failed"
  sign_off_refused "QA's latest Deployment of 0.3.0-rc.1 is failure (the Playwright demo failed): $qa_run" || return 1
  qa_tested in_progress
  sign_off_refused "QA's latest Deployment of 0.3.0-rc.1 is in_progress"
}
check "sign-off.sh refuses unless QA's latest Deployment of the candidate succeeded (failed, still running)" \
  latest_failed_refused
no_deployments
qa_tested success

# shellcheck disable=SC2317 # run through check, which ShellCheck can't follow here
missing_image_refused() {
  mv "$(image eshop-sync-master 0.3.0-rc.1)" "$work/held"
  sign_off_refused 'candidate image docker.io/pkhamdee/eshop-sync-master:0.3.0-rc.1 is missing'
  local refused=$?
  mv "$work/held" "$(image eshop-sync-master 0.3.0-rc.1)"
  return $refused
}
check "sign-off.sh refuses when a candidate image is missing (copies none)" missing_image_refused
missing_sbom_refused() {
  mv "$(sbom_file eshop-web)" "$work/held-sbom"
  sign_off_refused 'candidate image docker.io/pkhamdee/eshop-web:0.3.0-rc.1 has no SBOM (ADR 0010)' \
    && grep -qF 'scripts/gates/attach-sbom.sh --earlier-build docker.io/pkhamdee/eshop-web:0.3.0-rc.1 /dev/null' "$work/out"
  local refused=$?
  mv "$work/held-sbom" "$(sbom_file eshop-web)"
  return $refused
}
check "sign-off.sh refuses when a candidate image has no SBOM, saying how to attach one (copies none)" missing_sbom_refused
unreadable_sbom_refused() {
  FAKE_ORAS_DISCOVER_ERROR=1 sign_off_refused "could not read the SBOM of docker.io/pkhamdee/eshop-api@$(fake_digest eshop-api)"
}
check "sign-off.sh refuses when an SBOM can't be read (unknown is not absent)" unreadable_sbom_refused
other_release_image_refused() {
  echo sha256:other >"$(image eshop-web 0.3.0)"
  sign_off_refused 'docker.io/pkhamdee/eshop-web:0.3.0 already exists with a different digest'
  local refused=$?
  rm "$(image eshop-web 0.3.0)"
  return $refused
}
check "sign-off.sh refuses to overwrite a release image with another digest" other_release_image_refused
repointed_candidate_refused() {
  # The candidate's tag repointed after QA's promotion pinned its digest: QA never ran that image.
  local repointed
  repointed=sha256:$(printf 'd%.0s' $(seq 64))
  echo "$repointed" >"$(image eshop-web 0.3.0-rc.1)"
  sign_off_refused "docker.io/pkhamdee/eshop-web:0.3.0-rc.1 is $repointed, not $(fake_digest eshop-web) as eshop-qa's pin on main has it"
  local refused=$?
  fake_digest eshop-web >"$(image eshop-web 0.3.0-rc.1)"
  return $refused
}
check "sign-off.sh refuses when a candidate image's digest differs from the one QA's pin on main has (the tag was repointed)" \
  repointed_candidate_refused
record_digest_refused() {
  # The record (what a rollback to 0.3.0 pins) lists another digest than the candidate's.
  local saved_before=$before saved_after=$after other
  other=sha256:$(printf 'd%.0s' $(seq 64))
  sed "s/$(fake_digest eshop-node-api)/$other/" "$clone/releases/0.3.0.md" >"$work/record" \
    && mv "$work/record" "$clone/releases/0.3.0.md"
  git -C "$clone" commit -qam "Sign off v0.3.0-rc.1" && git -C "$clone" push -q origin HEAD:main
  before=$after after=$(origin rev-parse refs/heads/main)
  sign_off_refused "releases/0.3.0.md lists docker.io/pkhamdee/eshop-node-api:0.3.0-rc.1@$other, but its digest is $(fake_digest eshop-node-api)"
  local refused=$?
  git -C "$clone" reset -q --hard HEAD~1 && git -C "$clone" push -q --force origin HEAD:main
  before=$saved_before after=$saved_after
  return $refused
}
check "sign-off.sh refuses when the record lists another digest than the candidate's (a rollback pins the record's)" \
  record_digest_refused
released_refused() {
  git -C "$clone" tag -a v0.3.0 -m "Release 0.3.0" origin/main # not this candidate's commit, not a sign-off
  git -C "$clone" push -q origin refs/tags/v0.3.0
  sign_off_refused 'v0.3.0 already exists and is not a sign-off of v0.3.0-rc.1'
}
check "sign-off.sh refuses when vX.Y.Z already exists (released otherwise)" released_refused

wrong_record_refused() {
  sign_off_setup sign-off-wrong-record
  before=$(origin rev-parse refs/heads/main)
  mkdir -p "$clone/releases" && printf '# Release 0.4.0\n\nCandidate: %s\n' "\`v0.3.0-rc.1\`" >"$clone/releases/0.4.0.md"
  git -C "$clone" add releases && git -C "$clone" commit -qm "Sign off" && git -C "$clone" push -q origin HEAD:main
  after=$(origin rev-parse refs/heads/main)
  sign_off_refused 'releases/0.4.0.md names candidate 0.3.0-rc.1, which is not a candidate of 0.4.0'
}
check "sign-off.sh refuses a record whose candidate is not of its version" wrong_record_refused

same_digests() { # every service's 0.3.0 image exists with its candidate's digest
  local svc
  for svc in $services; do
    [ -f "$(image "$svc" 0.3.0)" ] && [ "$(cat "$(image "$svc" 0.3.0)")" = "$(fake_digest "$svc")" ] || return 1
  done
}
release_sboms() { # the Release's assets: every image's SBOM, as <service>-0.3.0.cdx.json
  local svc
  [ "$(find "$GH_STATE/release-v0.3.0-assets" -type f | wc -l)" -eq "$(wc -w <<<"$services")" ] || return 1
  for svc in $services; do
    [ "$(jq -r .service "$GH_STATE/release-v0.3.0-assets/$svc-0.3.0.cdx.json")" = "$svc" ] || return 1
  done
  grep -qE '^gh release upload v0.3.0 --repo pkhamdee/eshop-infra --clobber ' "$GH_LOG"
}
signs_off() {
  signed_off_setup sign-off || return 1
  : >"$GH_LOG"; : >"$CRANE_LOG"
  sign_off || return 1
  local release="$GH_STATE/release-v0.3.0" pr="$GH_STATE/pr-promote_prod-0.3.0"
  [ "$(origin cat-file -t refs/tags/v0.3.0)" = tag ] \
    && [ "$(origin rev-parse 'refs/tags/v0.3.0^{commit}')" = "$rc_commit" ] \
    && origin cat-file tag refs/tags/v0.3.0 | grep -qF 'Signed off from v0.3.0-rc.1 by @qa-lead' \
    && origin cat-file tag refs/tags/v0.3.0 | grep -qF 'https://github.com/test/pull/5' \
    && same_digests \
    && grep -qE '^crane copy docker.io/pkhamdee/eshop-api@sha256:[0-9a-f]+ docker.io/pkhamdee/eshop-api:0.3.0$' "$CRANE_LOG" \
    && lists_images "$release" 0.3.0 \
    && grep -qF "$qa_run" "$release" && grep -qF '@qa-lead' "$release" && grep -qF 'https://github.com/test/pull/5' "$release" \
    && grep -qF 'gh release create v0.3.0 --repo pkhamdee/eshop-infra --verify-tag' "$GH_LOG" \
    && release_sboms && grep -qxF '### SBOMs' "$release" \
    && [ "$(origin log -1 --format=%s refs/heads/promote/prod-0.3.0)" = "eshop-prod: deploy v0.3.0" ] \
    && [ "$(origin show refs/heads/promote/prod-0.3.0:clusters/local/prod-release.yaml | grep -c '"0.3.0" # release-pin: prod$')" -ge 2 ] \
    && origin show refs/heads/promote/prod-0.3.0:clusters/local/prod-release.yaml \
      | grep -qxF "      digest: \"$(fake_digest eshop-sync-master)\" # release-pin: prod" \
    && lists_images "$pr" 0.3.0 && grep -qF "$qa_run" "$pr" && grep -qF '@qa-lead' "$pr" \
    && grep -qF 'https://github.com/test/releases/tag/v0.3.0' "$pr" \
    && grep -qF 'Promotion PR: https://github.com/test/pull/1' "$work/out"
}
check "sign-off.sh on the merged sign-off PR tags vX.Y.Z on the candidate's commit (naming the merger), copies its images by digest, publishes the Release with each image's SBOM and opens the prod promotion PR" \
  signs_off
signs_off_again() { # after signs_off: the same sign-off again finds every step done and updates the Release and PR
  local tag_object
  tag_object=$(origin rev-parse refs/tags/v0.3.0)
  git -C "$clone" checkout -q main
  : >"$GH_LOG"; : >"$CRANE_LOG"
  sign_off \
    && [ "$(origin rev-parse refs/tags/v0.3.0)" = "$tag_object" ] && same_digests \
    && ! grep -q '^crane copy' "$CRANE_LOG" \
    && grep -q '^gh release edit v0.3.0' "$GH_LOG" && ! grep -q '^gh release create' "$GH_LOG" && release_sboms \
    && grep -q '^gh pr edit' "$GH_LOG" && ! grep -q '^gh pr create' "$GH_LOG"
}
check "sign-off.sh run again (a re-run of the job) changes no tag or image and updates the Release and the PR" \
  signs_off_again
finishes_interrupted_sign_off() {
  signed_off_setup sign-off-interrupted || return 1
  FAKE_CRANE_FAIL_COPY=docker.io/pkhamdee/eshop-web sign_off && return 1
  grep -qF 'copy to docker.io/pkhamdee/eshop-web:0.3.0 failed' "$work/out" || return 1
  # Stopped while copying images: no tag, Release or PR names images that don't exist.
  [ -z "$(origin tag -l v0.3.0)" ] && [ ! -e "$GH_STATE/release-v0.3.0" ] || return 1
  git -C "$clone" checkout -q main
  sign_off && same_digests \
    && [ "$(origin rev-parse 'refs/tags/v0.3.0^{commit}')" = "$rc_commit" ] \
    && [ -e "$GH_STATE/release-v0.3.0" ] && [ -e "$GH_STATE/pr-promote_prod-0.3.0" ]
}
check "sign-off.sh interrupted half-way is finished by running it again" finishes_interrupted_sign_off
no_deployments

# --- scripts/gate-reports.sh (each candidate image's CI run and gate reports: the QA promotion PR, the sign-off record) ---

# A fresh origin (for .github/services.json) and a registry of 0.3.0-rc.1 images: eshop-api and eshop-sync-master
# built from one eshop-api commit, eshop-web from its own, thirdparty-mock with no revision label.
reports_setup() {
  clone=$(fresh "$1")
  rm -rf "${GH_STATE:?}"/*
  export REGISTRY="$work/$1/registry"
  mkdir -p "$REGISTRY/.revision"
  local svc
  for svc in eshop-api eshop-sync-master eshop-web thirdparty-mock; do
    mkdir -p "$(dirname "$(image "$svc" x)")" && fake_digest "$svc" >"$(image "$svc" 0.3.0-rc.1)"
  done
  echo aaaaaaa1111 >"$REGISTRY/.revision/$(fake_digest eshop-api)"
  echo aaaaaaa1111 >"$REGISTRY/.revision/$(fake_digest eshop-sync-master)"
  echo bbbbbbb2222 >"$REGISTRY/.revision/$(fake_digest eshop-web)"
}
reports() { (cd "$clone" && scripts/gate-reports.sh "$@") >"$work/out" 2>&1; }
candidate_image() { echo "docker.io/pkhamdee/$1:0.3.0-rc.1@$(fake_digest "$1")"; }
web_run=https://github.com/pkhamdee/eshop-web/actions/runs/400

links_the_run_that_pushed() {
  reports_setup gate-reports
  ci_run pkhamdee/eshop-api aaaaaaa1111 300 2026-10-01T00:00:00Z pull_request success # a PR's: never the image's
  ci_run pkhamdee/eshop-api aaaaaaa1111 303 2026-10-01T03:00:00Z workflow_dispatch success # later: pushed nothing new
  ci_run pkhamdee/eshop-api aaaaaaa1111 301 2026-10-01T01:00:00Z push skipped # a gate failed: pushed nothing
  ci_run pkhamdee/eshop-api aaaaaaa1111 302 2026-10-01T02:00:00Z workflow_dispatch success # the one that pushed
  reports "$(candidate_image eshop-api)" "$(candidate_image eshop-sync-master)" || return 1
  local links
  links="[CI run]($(api_run 302)), Locust [perf-report]($(api_run 302)/artifacts/3021), ZAP [dast-report]($(api_run 302)/artifacts/3022)"
  [ "$(cat "$work/out")" = "- eshop-api, built from \`aaaaaaa\` in pkhamdee/eshop-api: $links
- eshop-sync-master, built from \`aaaaaaa\` in pkhamdee/eshop-api: $links" ]
}
check "gate-reports.sh links the first run of the image's commit whose push job succeeded, and its Locust and ZAP reports (skipping failed, later and PR runs)" \
  links_the_run_that_pushed
each_image_its_own_run() { # after links_the_run_that_pushed: a patch image (its release/N.x build) and one carried
  # over from an earlier release resolve the same way, each to the run of the commit it was built from
  ci_run pkhamdee/eshop-web bbbbbbb2222 400 2026-09-01T00:00:00Z push success
  reports "$(candidate_image eshop-web)" "$(candidate_image eshop-api)" \
    && grep -qF -- "- eshop-web, built from \`bbbbbbb\` in pkhamdee/eshop-web: [CI run]($web_run), Locust [perf-report]($web_run/artifacts/4001)" "$work/out" \
    && grep -qF -- "- eshop-api, built from \`aaaaaaa\` in pkhamdee/eshop-api: [CI run]($(api_run 302))" "$work/out"
}
check "gate-reports.sh links each image to the run of the commit it was built from, in its service's repository" each_image_its_own_run
says_what_is_missing() {
  reports_setup gate-reports-missing
  ci_run pkhamdee/eshop-api aaaaaaa1111 301 2026-10-01T01:00:00Z push skipped
  ci_run pkhamdee/eshop-web bbbbbbb2222 400 2026-09-01T00:00:00Z push success \
    '{"artifacts":[{"id":4001,"name":"perf-report","expired":true,"created_at":"2026-09-01T00:00:00Z"}]}'
  reports "$(candidate_image eshop-api)" "$(candidate_image eshop-web)" "$(candidate_image thirdparty-mock)" \
    && grep -qxF -- "- eshop-api, built from \`aaaaaaa\` in pkhamdee/eshop-api: no CI run of that commit pushed it, so its gate reports can't be found" "$work/out" \
    && grep -qxF -- "- eshop-web, built from \`bbbbbbb\` in pkhamdee/eshop-web: [CI run]($web_run), Locust perf-report expired, ZAP dast-report not found in the run" "$work/out" \
    && grep -qF -- "- thirdparty-mock: no source commit (the image has no org.opencontainers.image.revision label)" "$work/out" \
    && FAKE_RUNS_ERROR=1 reports "$(candidate_image eshop-web)" \
    && grep -qxF -- "- eshop-web, built from \`bbbbbbb\` in pkhamdee/eshop-web: could not read its CI runs" "$work/out"
}
check "gate-reports.sh says on each image's line what it can't find (no label, no run that pushed, a report expired or missing, runs unreadable) and still succeeds" \
  says_what_is_missing
malformed_image_refused() {
  ! reports docker.io/pkhamdee/eshop-api:0.3.0-rc.1 && grep -qF 'not an image with its digest' "$work/out" \
    && ! reports && grep -qF 'usage: scripts/gate-reports.sh' "$work/out"
}
check "gate-reports.sh refuses an image without its digest, and no image at all" malformed_image_refused

# --- scripts/check-new-images.sh (CI's push job, before pushing a version's images) ---

export REGISTRY="$work/new-images/registry"
mkdir -p "$REGISTRY/docker.io/pkhamdee/eshop-api" "$REGISTRY/docker.io/pkhamdee/eshop-web"
echo sha256:aaaa >"$REGISTRY/docker.io/pkhamdee/eshop-api/0.3.0-rc.1"
echo sha256:bbbb >"$REGISTRY/docker.io/pkhamdee/eshop-web/0.2.0"
new_images() { (cd "$root" && scripts/check-new-images.sh "$@") >"$work/out" 2>&1; }

all_new_passes() { # eshop-web has other tags only; eshop-new has no repository yet
  new_images docker.io/pkhamdee/eshop-web:0.3.0-rc.1 docker.io/pkhamdee/eshop-new:0.3.0-rc.1
}
check "check-new-images.sh passes when no image exists yet (also in a repository not created yet)" all_new_passes
existing_refused() {
  ! new_images docker.io/pkhamdee/eshop-web:0.3.0-rc.1 docker.io/pkhamdee/eshop-api:0.3.0-rc.1 \
    && grep -qF 'docker.io/pkhamdee/eshop-api:0.3.0-rc.1' "$work/out" \
    && ! grep -qF 'eshop-web:0.3.0-rc.1' "$work/out" && grep -qF 'never overwritten' "$work/out"
}
check "check-new-images.sh refuses a version image that already exists, naming it" existing_refused
registry_error_fails() {
  ! FAKE_CRANE_LS_ERROR=1 new_images docker.io/pkhamdee/eshop-web:0.3.0-rc.1 \
    && grep -qF 'could not list the tags of docker.io/pkhamdee/eshop-web' "$work/out"
}
check "check-new-images.sh fails when it can't tell (a registry error is not \"absent\")" registry_error_fails
usage_refused() { ! new_images && grep -qF 'usage: scripts/check-new-images.sh' "$work/out"; }
check "check-new-images.sh needs at least one image" usage_refused

# --- scripts/smoke-targets.sh (e2e.yml's first job: what a push to main, or a dispatch, smoke-tests) ---

clone=$(fresh smoke-targets)
targets() { (cd "$clone" && scripts/smoke-targets.sh "$@") >"$work/out" 2>&1; }
pushed() { # pushed <file> <subject>: commits a change to <file> on main and pushes it; prints before and after
  local before
  before=$(git -C "$clone" rev-parse HEAD)
  mkdir -p "$clone/$(dirname "$1")" && echo "$2" >>"$clone/$1"
  git -C "$clone" add "$1" && git -C "$clone" commit -qm "$2" && git -C "$clone" push -q origin HEAD:main
  echo "$before $(git -C "$clone" rev-parse HEAD)"
}
ordinary_push_tests_dev() {
  # shellcheck disable=SC2046 # two SHAs
  set -- $(pushed eshop-api/README.md "a change") && targets push "$1" "$2" && [ "$(cat "$work/out")" = "dev $2" ]
}
check "smoke-targets.sh push: an ordinary commit is dev at that commit" ordinary_push_tests_dev
flux_image_push_tests_dev() {
  # shellcheck disable=SC2046
  set -- $(pushed deploy/apps/dev/kustomization.yaml "chore: update images") \
    && targets push "$1" "$2" && [ "$(cat "$work/out")" = "dev $2" ]
}
check "smoke-targets.sh push: Flux's image-update commit is dev at that commit" flux_image_push_tests_dev
unknown_commit_refused() { ! targets push "$(git -C "$clone" rev-parse HEAD)" 0123456789abcdef0123456789abcdef01234567; }
check "smoke-targets.sh push: refuses an after-commit it doesn't have" unknown_commit_refused
dispatched_dev_is_main() {
  local main
  main=$(git -C "$clone" rev-parse origin/main)
  targets dispatch dev && [ "$(cat "$work/out")" = "dev $main" ] \
    && targets dispatch dev "${main:0:7}" && [ "$(cat "$work/out")" = "dev $main" ]
}
check "smoke-targets.sh dispatch dev: main's head, or the commit given (short or full)" dispatched_dev_is_main
dispatched_versions() {
  targets dispatch qa 0.3.0-rc.1 && [ "$(cat "$work/out")" = "qa 0.3.0-rc.1" ] \
    && targets dispatch prod 0.2.1 && [ "$(cat "$work/out")" = "prod 0.2.1" ] \
    && targets dispatch prod && [ "$(cat "$work/out")" = "prod 0.2.0" ]
}
check "smoke-targets.sh dispatch qa|prod: the version given; prod without one is its pin on main" dispatched_versions
dispatch_refusals() {
  ! targets dispatch qa && grep -qF 'X.Y.Z-rc.N' "$work/out" \
    && ! targets dispatch prod 0.3.0-rc.1 && grep -qF 'a release X.Y.Z' "$work/out" \
    && ! targets dispatch staging && grep -qF 'usage: scripts/smoke-targets.sh' "$work/out"
}
check "smoke-targets.sh dispatch refuses QA without a candidate, a version the environment doesn't take, and other environments" \
  dispatch_refusals

# --- scripts/smoke-targets.sh push: promotions and rollbacks (a push changing `# release-pin: <env>` lines) ---

clone=$(fresh promotion-targets)
promoted() { # promoted <env> <version>...: pins each <env> to its <version> in one commit pushed to main; prints before, after
  local before
  before=$(git -C "$clone" rev-parse HEAD)
  while [ $# -gt 0 ]; do pin_in_clone "$1" "$2" || return 1; shift 2; done
  git -C "$clone" commit -qam "promote" && git -C "$clone" push -q origin HEAD:main
  echo "$before $(git -C "$clone" rev-parse HEAD)"
}
suspended_placeholder_tests_nothing() {
  local f="$clone/clusters/local/qa-release.yaml"
  # QA's placeholder changed by hand, its `# release-pin-until: qa` line kept: still nothing deployed to test.
  sed -E 's|: "0.2.0" (# release-pin: qa)$|: "0.2.1" \1|' "$f" >"$f.new" && mv "$f.new" "$f"
  # shellcheck disable=SC2046 # two SHAs
  set -- $(promoted) && targets push "$1" "$2" && [ ! -s "$work/out" ] \
    && grep -q ' # release-pin-until: qa$' "$f"
}
check "smoke-targets.sh push: a pin change to a suspended environment tests nothing (nor dev)" suspended_placeholder_tests_nothing
qa_promotion_tests_qa() {
  # shellcheck disable=SC2046
  set -- $(promoted qa 0.3.0-rc.1) && targets push "$1" "$2" && [ "$(cat "$work/out")" = "qa 0.3.0-rc.1" ]
}
check "smoke-targets.sh push: a QA promotion (its first, unsuspending QA) is qa at the candidate, not dev" qa_promotion_tests_qa
prod_promotion_tests_prod() {
  # shellcheck disable=SC2046
  set -- $(promoted prod 0.3.0) && targets push "$1" "$2" && [ "$(cat "$work/out")" = "prod 0.3.0" ]
}
check "smoke-targets.sh push: a prod promotion is prod at the release, not dev" prod_promotion_tests_prod
both_promoted_tests_both() {
  # shellcheck disable=SC2046
  set -- $(promoted qa 0.4.0-rc.1 prod 0.3.1) && targets push "$1" "$2" \
    && [ "$(cat "$work/out")" = "$(printf 'prod 0.3.1\nqa 0.4.0-rc.1')" ]
}
check "smoke-targets.sh push: a push moving both pins is both environments, each at its version" both_promoted_tests_both
rollback_tests_earlier_release() {
  # shellcheck disable=SC2046
  set -- $(promoted prod 0.3.0) && targets push "$1" "$2" && [ "$(cat "$work/out")" = "prod 0.3.0" ]
}
check "smoke-targets.sh push: a rollback (prod back to an earlier release) is prod at that release" rollback_tests_earlier_release
pin_with_other_lines_tests_dev_too() {
  local f="$clone/clusters/local/qa-release.yaml"
  echo "# a comment beside the pin" >>"$f"
  # shellcheck disable=SC2046
  set -- $(promoted qa 0.4.0-rc.2) && targets push "$1" "$2" \
    && [ "$(cat "$work/out")" = "$(printf 'qa 0.4.0-rc.2\ndev %s' "$2")" ] \
    && set -- $(promoted qa 0.4.0-rc.3 && pushed eshop-api/README.md "a change") \
    && targets push "$1" "$4" && [ "$(cat "$work/out")" = "$(printf 'qa 0.4.0-rc.3\ndev %s' "$4")" ]
}
check "smoke-targets.sh push: a pin change with other lines, in the pin files or elsewhere, is the environment and dev" \
  pin_with_other_lines_tests_dev_too
other_lines_in_pin_files_test_dev() {
  # shellcheck disable=SC2046
  set -- $(pushed clusters/local/prod-release.yaml "# not a pin") && targets push "$1" "$2" \
    && [ "$(cat "$work/out")" = "dev $2" ]
}
check "smoke-targets.sh push: other lines of the pin files, no pin changed, are dev only" other_lines_in_pin_files_test_dev

# --- scripts/smoke-result.sh (e2e.yml: is the target still the environment's, and how did its test end) ---

# QA and prod runs aren't cancelled by newer ones and may overlap: a run whose version is no longer its environment's
# pin on main (a newer promotion merged) tested nothing that matters, and says so as `superseded`.
clone=$(fresh smoke-result)
result() { (cd "$clone" && scripts/smoke-result.sh "$@") >"$work/out" 2>&1; }
promoted qa 0.3.0-rc.1 prod 0.3.0 >/dev/null
still_pinned_is_current() {
  result current qa 0.3.0-rc.1 && result current prod 0.3.0 && result current dev "$(git -C "$clone" rev-parse HEAD)"
}
check "smoke-result.sh current: a version still its environment's pin on main is current (dev always is)" \
  still_pinned_is_current
moved_pin_is_superseded() {
  local status=0
  result current qa 0.3.0-rc.2 || status=$?
  [ "$status" = 1 ] && [ "$(cat "$work/out")" = "eshop-qa is pinned to 0.3.0-rc.1 on main now, not 0.3.0-rc.2" ]
}
check "smoke-result.sh current: a version no longer its environment's pin on main is not (exit 1, saying what is)" \
  moved_pin_is_superseded
retried_file() { printf '%s\n' "desktop: tests/demo.spec.ts › the demo" >"$work/retried.txt"; echo "$work/retried.txt"; }
outcome_is() { # outcome_is <expected line> <smoke-result.sh of args...>
  local expected=$1; shift
  result of "$@" && [ "$(cat "$work/out")" = "$expected" ]
}
results_by_job_status() {
  local head
  head=$(git -C "$clone" rev-parse HEAD)
  outcome_is passed qa 0.3.0-rc.1 success success \
    && outcome_is passed qa 0.3.0-rc.1 success success "$work/none.txt" \
    && outcome_is retried prod 0.3.0 success success "$(retried_file)" \
    && outcome_is not-deployed qa 0.3.0-rc.1 failure failure \
    && outcome_is failed qa 0.3.0-rc.1 failure success \
    && outcome_is failed dev "$head" failure success \
    && outcome_is cancelled prod 0.3.0 cancelled success \
    && outcome_is superseded dev "$head" cancelled skipped
}
check "smoke-result.sh of: passed, retried (a test passed only on retry), not-deployed (the wait failed), failed, cancelled (QA or prod, by hand) and superseded (dev, by a newer run)" \
  results_by_job_status
failure_after_promotion_is_superseded() {
  outcome_is "superseded eshop-qa is pinned to 0.3.0-rc.1 on main now, not 0.2.9-rc.1" qa 0.2.9-rc.1 failure failure \
    && outcome_is "superseded eshop-qa is pinned to 0.3.0-rc.1 on main now, not 0.2.9-rc.1" qa 0.2.9-rc.1 failure success \
    && outcome_is "superseded eshop-prod is pinned to 0.3.0 on main now, not 0.2.0" prod 0.2.0 cancelled success \
    && outcome_is passed prod 0.2.0 success success # it passed before prod moved on: the pass stands
}
check "smoke-result.sh of: a QA or prod run that failed or was cancelled after a newer promotion merged is superseded, saying why" \
  failure_after_promotion_is_superseded
suspended_is_superseded() {
  local f="$clone/clusters/local/qa-release.yaml"
  cp "$f" "$work/qa-release.yaml"
  cp "$clusters/qa-release.yaml" "$f" && git -C "$clone" commit -qam "suspend QA" && git -C "$clone" push -q origin HEAD:main
  local status=0
  result current qa 0.3.0-rc.1 || status=$?
  cp "$work/qa-release.yaml" "$f" && git -C "$clone" commit -qam "back" && git -C "$clone" push -q origin HEAD:main
  [ "$status" = 1 ] && grep -qF "apps-qa is suspended on main now" "$work/out"
}
check "smoke-result.sh current: an environment suspended again on main is not current" suspended_is_superseded
result_refusals() {
  ! result of qa 0.3.0 success success && grep -qF 'usage: scripts/smoke-result.sh' "$work/out" \
    && ! result of qa 0.3.0-rc.1 green success && grep -qF 'usage: scripts/smoke-result.sh' "$work/out" \
    && ! result current staging 1.0.0 && grep -qF 'usage: scripts/smoke-result.sh' "$work/out"
}
check "smoke-result.sh refuses a target its environment doesn't take, an unknown job status and an unknown environment" \
  result_refusals

# --- scripts/deployment.sh (e2e.yml: each target's GitHub Deployment and its statuses) ---

deployment() { (cd "$root" && scripts/deployment.sh "$@") >"$work/out" 2>&1; }
run_url=https://github.com/test/actions/runs/7
dev_url=https://eshop.localhost
dep() { cat "$GH_STATE/deployments/$1.json"; }                             # dep <id>: the create body
statuses() { jq -s . "$GH_STATE/deployments/$1.statuses" 2>/dev/null || echo '[]'; } # oldest first
dev_commit=0123456789abcdef0123456789abcdef01234567
starts_in_progress() {
  deployment start dev "$dev_commit" "$run_url" "$dev_url" || return 1
  local id
  id=$(cat "$work/out")
  dep "$id" | jq -e --arg ref "$dev_commit" \
      '.ref == $ref and .environment == "dev" and .auto_merge == false and .required_contexts == []' >/dev/null \
    && statuses "$id" | jq -e --arg log "$run_url" --arg url "$dev_url" \
      'length == 1 and .[0].state == "in_progress" and .[0].log_url == $log and .[0].environment_url == $url' >/dev/null
}
check "deployment.sh start creates a Deployment of the ref to the environment (no auto-merge, no required contexts), in progress, and prints its id" \
  starts_in_progress
finishes() { # finishes <state> [description]: a new Deployment finished with that state ends with exactly that status
  deployment start dev "$dev_commit" "$run_url" "$dev_url" || return 1
  local id
  id=$(cat "$work/out")
  deployment finish "$id" "$1" "$run_url" "$dev_url" ${2:+"$2"} \
    && statuses "$id" | jq -e --arg state "$1" --arg log "$run_url" --arg url "$dev_url" --arg d "${2:-}" \
      '(map(.state) == ["in_progress", $state]) and .[1].log_url == $log and .[1].environment_url == $url
       and (.[1].description // "") == $d' >/dev/null
}
check "deployment.sh finish <id> success records success, linked to the run and the environment" finishes success
check "deployment.sh finish <id> failure <description> records failure and why" \
  finishes failure "eshop-dev is not serving main at 0123456: not deployed after 900s"
check "deployment.sh finish <id> inactive superseded records inactive, superseded" finishes inactive superseded
long_description_cut() {
  deployment start dev "$dev_commit" "$run_url" "$dev_url" || return 1
  local id
  id=$(cat "$work/out")
  deployment finish "$id" failure "$run_url" "$dev_url" "$(printf 'x%.0s' {1..200})" \
    && statuses "$id" | jq -e '.[1].description | length == 140' >/dev/null
}
check "deployment.sh finish cuts a description to GitHub's 140 characters" long_description_cut
finish_refusals() {
  ! deployment finish 1 passed "$run_url" "$dev_url" && grep -qF 'usage: scripts/deployment.sh' "$work/out" \
    && ! deployment start staging "$dev_commit" "$run_url" "$dev_url" && grep -qF 'usage: scripts/deployment.sh' "$work/out"
}
check "deployment.sh refuses an unknown state or environment" finish_refusals
sweeps_abandoned() {
  rm -rf "$GH_STATE/deployments" "$GH_STATE"/run-*
  local older running finished qa own
  # Runs 5 and 6 (attempt 1) have ended, run 8 is still going (an overlapping QA or prod run), as is run 7 (own).
  echo in_progress >"$GH_STATE/run-8-1"; echo in_progress >"$GH_STATE/run-7-1"
  GITHUB_RUN_ID=5 deployment start dev 1111111111111111111111111111111111111111 "$run_url" "$dev_url" && older=$(cat "$work/out")
  GITHUB_RUN_ID=8 deployment start dev 3333333333333333333333333333333333333333 "$run_url" "$dev_url" && running=$(cat "$work/out")
  GITHUB_RUN_ID=6 deployment start dev 2222222222222222222222222222222222222222 "$run_url" "$dev_url" && finished=$(cat "$work/out")
  deployment finish "$finished" success "$run_url" "$dev_url"
  GITHUB_RUN_ID=5 deployment start qa v0.3.0-rc.1 "$run_url" https://qa.eshop.localhost && qa=$(cat "$work/out")
  deployment start dev "$dev_commit" "$run_url" "$dev_url" && own=$(cat "$work/out")
  deployment sweep dev "$own" \
    && statuses "$older" | jq -e 'map(.state) == ["in_progress", "inactive"] and (.[1].description | startswith("abandoned"))' >/dev/null \
    && statuses "$running" | jq -e 'map(.state) == ["in_progress"]' >/dev/null \
    && statuses "$finished" | jq -e 'map(.state) == ["in_progress", "success"]' >/dev/null \
    && statuses "$qa" | jq -e 'map(.state) == ["in_progress"]' >/dev/null \
    && statuses "$own" | jq -e 'map(.state) == ["in_progress"]' >/dev/null
}
check "deployment.sh sweep <env> <id> marks the environment's other in-progress Deployments whose run has ended inactive, abandoned (a running run's, finished ones, other environments' and its own untouched)" \
  sweeps_abandoned
rm -rf "$GH_STATE/deployments" "$GH_STATE"/run-*

# Only a run on main records a Deployment, and says so in its payload: nothing else counts as evidence.
records_workflow_ref() {
  deployment start qa v0.3.0-rc.1 "$run_url" "$qa_url" || return 1
  dep "$(cat "$work/out")" | jq -e --arg run "$run_url" \
    '.payload == {workflow_ref: "refs/heads/main", run_url: $run, run_id: "7", run_attempt: "1"}' >/dev/null
}
qa_url=https://qa.eshop.localhost
check "deployment.sh start records which ref ran it and which run attempt in the Deployment's payload" records_workflow_ref
off_main_refused() {
  rm -rf "$GH_STATE/deployments"
  ! GITHUB_REF=refs/heads/feature deployment start qa v0.3.0-rc.1 "$run_url" "$qa_url" \
    && grep -qF 'only from a run on main (this run: refs/heads/feature)' "$work/out" && [ ! -d "$GH_STATE/deployments" ]
}
check "deployment.sh start refuses, recording nothing, in a run that isn't on main" off_main_refused
rm -rf "$GH_STATE/deployments"

# A promotion's (or rollback's) Deployment that succeeds replaces the environment's previous successful one.
started() { deployment start "$@" "$run_url" "https://$1.eshop.localhost" && cat "$work/out"; } # started <env> <ref>
success_replaces_previous_success() {
  rm -rf "$GH_STATE/deployments"
  local first failed prod previous own
  first=$(started qa v0.3.0-rc.1) && deployment finish "$first" success "$run_url" "$qa_url"
  previous=$(started qa v0.3.0-rc.2) && deployment finish "$previous" success "$run_url" "$qa_url"
  failed=$(started qa v0.3.0-rc.3) && deployment finish "$failed" failure "$run_url" "$qa_url" "the Playwright demo failed"
  prod=$(started prod v0.2.0) && deployment finish "$prod" success "$run_url" https://prod.eshop.localhost
  own=$(started qa v0.3.0-rc.1) || return 1 # a rollback to rc.1
  deployment finish "$own" success "$run_url" "$qa_url" \
    && statuses "$previous" | jq -e 'map(.state) == ["in_progress", "success", "inactive"]
         and .[2].description == "replaced by v0.3.0-rc.1"' >/dev/null \
    && statuses "$first" | jq -e 'map(.state) == ["in_progress", "success", "inactive"]' >/dev/null \
    && statuses "$failed" | jq -e 'map(.state) == ["in_progress", "failure"]' >/dev/null \
    && statuses "$prod" | jq -e 'map(.state) == ["in_progress", "success"]' >/dev/null \
    && statuses "$own" | jq -e 'map(.state) == ["in_progress", "success"]' >/dev/null
}
check "deployment.sh finish <id> success marks the environment's previous successful Deployments inactive (failed ones, other environments' and its own untouched)" \
  success_replaces_previous_success
failure_keeps_previous_success() {
  rm -rf "$GH_STATE/deployments"
  local previous own
  previous=$(started prod v0.3.0) && deployment finish "$previous" success "$run_url" https://prod.eshop.localhost
  own=$(started prod v0.3.1) || return 1
  deployment finish "$own" failure "$run_url" https://prod.eshop.localhost "the Playwright demo failed" \
    && statuses "$previous" | jq -e 'map(.state) == ["in_progress", "success"]' >/dev/null
}
check "deployment.sh finish <id> failure leaves the previous successful Deployment as it is" failure_keeps_previous_success
rm -rf "$GH_STATE/deployments"

# --- scripts/notify.sh (e2e.yml's notify job: a smoke test's result by email) ---

# Fake curl: logs its arguments to $CURL_LOG, keeps the --config it reads on stdin (the credentials) as
# $CURL_MAIL.config and the message it would upload (--upload-file) as $CURL_MAIL, also appended to $CURL_MAIL.all
# (every message since notify() started). Sends nothing.
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" >>"$CURL_LOG"
while [ $# -gt 0 ]; do
  case "$1" in
    --upload-file) cp "$2" "$CURL_MAIL"; cat "$2" >>"$CURL_MAIL.all" ;;
    --config) [ "$2" != - ] || cat >"$CURL_MAIL.config" ;;
  esac
  shift
done
CURL
chmod +x "$work/bin/curl"
export CURL_LOG="$work/curl.log" CURL_MAIL="$work/mail"
smtp_password=not-a-real-app-password
# notify <args>: scripts/notify.sh with every SMTP setting (each overridable, '' for missing), the mail it sent (if
# any) in $CURL_MAIL. Output in $work/out.
notify() {
  rm -f "$CURL_MAIL" "$CURL_MAIL.config" "$CURL_MAIL.all"; : >"$CURL_LOG"
  (cd "$root" && SMTP_USERNAME=${SMTP_USERNAME-eshop.smoke@example.com} SMTP_PASSWORD=${SMTP_PASSWORD-$smtp_password} \
    NOTIFY_EMAIL=${NOTIFY_EMAIL-team@example.com} RUN_URL=$run_url REPORT_URL=$run_url/artifacts/99 \
    scripts/notify.sh "$@") >"$work/out" 2>&1
}
subject() { sed -n 's/^Subject: //p' "$CURL_MAIL" | tr -d '\r'; }
mailed() { [ -f "$CURL_MAIL" ]; }
prod_pass_mailed() {
  rm -rf "$GH_STATE/deployments"
  local id
  id=$(started prod v0.3.0) && deployment finish "$id" success "$run_url" https://prod.eshop.localhost
  notify prod 0.3.0 passed "$id" \
    && [ "$(subject)" = "[eShop] prod v0.3.0: deployed and smoke test passed" ] \
    && grep -qF "$run_url/artifacts/99" "$CURL_MAIL" && grep -qF "Run: $run_url" "$CURL_MAIL" \
    && grep -qF -- '--ssl-reqd' "$CURL_LOG" && grep -qF 'smtps://smtp.gmail.com:465' "$CURL_LOG" \
    && grep -qF -- '--mail-from eshop.smoke@example.com' "$CURL_LOG" && grep -qF -- '--mail-rcpt team@example.com' "$CURL_LOG" \
    && grep -qF "eshop.smoke@example.com:$smtp_password" "$CURL_MAIL.config" \
    && ! grep -qF "$smtp_password" "$CURL_LOG" "$work/out" "$CURL_MAIL"
}
check "notify.sh: a prod pass is mailed over SMTPS (Gmail, port 465), \"[eShop] prod v0.3.0: deployed and smoke test passed\", with the run and the Playwright report; the password never on the command line or in the output" \
  prod_pass_mailed
qa_failure_mailed() {
  DETAIL="the Playwright demo failed" notify qa 0.3.1-rc.1 failed \
    && [ "$(subject)" = "[eShop] qa v0.3.1-rc.1: smoke test FAILED" ] \
    && grep -qF "the Playwright demo failed" "$CURL_MAIL" && ! grep -qF "Rollback" "$CURL_MAIL"
}
check "notify.sh: a QA failure is mailed, \"[eShop] qa v0.3.1-rc.1: smoke test FAILED\", saying why" qa_failure_mailed
qa_retry_mailed() {
  printf '%s\n' "desktop: tests/demo.spec.ts › the demo" >"$work/retried.txt"
  RETRIED_FILE="$work/retried.txt" notify qa 0.3.0-rc.2 retried \
    && [ "$(subject)" = "[eShop] qa v0.3.0-rc.2: deployed and smoke test passed on retry" ] \
    && grep -qF -- "- desktop: tests/demo.spec.ts › the demo" "$CURL_MAIL"
}
check "notify.sh: a QA pass on retry is mailed as such, naming the tests that passed only on retry" qa_retry_mailed
qa_not_deployed_mailed() {
  notify qa 0.3.0-rc.2 not-deployed && [ "$(subject)" = "[eShop] qa v0.3.0-rc.2: NOT DEPLOYED, smoke test FAILED" ]
}
check "notify.sh: QA not serving the candidate is mailed as not deployed" qa_not_deployed_mailed
# Prod: v0.2.0 passed and was replaced by v0.2.1 (inactive now), which passed; v0.3.0 failed; now v0.3.1 fails.
prod_failure_names_rollback() {
  rm -rf "$GH_STATE/deployments"
  local id
  id=$(started prod v0.2.0) && deployment finish "$id" success "$run_url" https://prod.eshop.localhost
  id=$(started prod v0.2.1) && deployment finish "$id" success "$run_url" https://prod.eshop.localhost
  id=$(started prod v0.3.0) && deployment finish "$id" failure "$run_url" https://prod.eshop.localhost "failed"
  id=$(started prod v0.3.1) && deployment finish "$id" failure "$run_url" https://prod.eshop.localhost "failed"
  notify prod 0.3.1 failed "$id" \
    && [ "$(subject)" = "[eShop] prod v0.3.1: smoke test FAILED" ] \
    && grep -qF "the last release that passed in prod is v0.2.1" "$CURL_MAIL" \
    && grep -qF "  scripts/promotion-pr.sh prod 0.2.1" "$CURL_MAIL" && grep -qF "scripts/pin-release.sh prod 0.2.1" "$CURL_MAIL"
}
check "notify.sh: a prod failure names the last release whose prod Deployment succeeded and the rollback (promotion-pr.sh / pin-release.sh)" \
  prod_failure_names_rollback
prod_failure_without_earlier_pass() {
  rm -rf "$GH_STATE/deployments"
  notify prod 0.3.0 not-deployed && grep -qF "no earlier release passed in prod" "$CURL_MAIL"
}
check "notify.sh: a prod failure with no earlier passing release says there is none to roll back to" \
  prod_failure_without_earlier_pass
# Dev: mailed on a failure, and on the first pass after one (dev's previous Deployment with an outcome).
dev_finished() { # dev_finished <commit> <state> [description]: prints the Deployment's id
  local id
  id=$(started dev "$1") && deployment finish "$id" "$2" "$run_url" "$dev_url" ${3:+"$3"} && echo "$id"
}
dev_rules() {
  rm -rf "$GH_STATE/deployments"
  local a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local c=cccccccccccccccccccccccccccccccccccccccc d=dddddddddddddddddddddddddddddddddddddddd id
  id=$(dev_finished "$a" success) && notify dev "$a" passed "$id" && ! mailed || return 1 # the first ever: no
  id=$(dev_finished "$b" success) && notify dev "$b" passed "$id" && ! mailed || return 1 # a pass after a pass: no
  id=$(dev_finished "$c" failure "the Playwright demo failed") && notify dev "$c" failed "$id" \
    && [ "$(subject)" = "[eShop] dev ccccccc: smoke test FAILED" ] || return 1 # a failure: yes
  dev_finished "$d" inactive superseded >/dev/null || return 1 # superseded: tested nothing
  id=$(dev_finished "$d" success) && notify dev "$d" retried "$id" \
    && [ "$(subject)" = "[eShop] dev ddddddd: deployed and smoke test passed on retry" ] \
    && grep -qF "previous smoke test, of ccccccc, had failed" "$CURL_MAIL" || return 1 # the first pass after: yes
  id=$(dev_finished "$a" success) && notify dev "$a" passed "$id" && ! mailed # and the next pass: no
}
check "notify.sh: dev is mailed only a failure and the first pass after one (a superseded Deployment skipped)" dev_rules
missing_setting_fails() {
  local status=0
  SMTP_PASSWORD='' notify prod 0.3.0 passed || status=$?
  [ "$status" = 1 ] && grep -qF 'no SMTP_PASSWORD' "$work/out" && ! mailed && [ ! -s "$CURL_LOG" ] || return 1
  status=0
  NOTIFY_EMAIL='' SMTP_USERNAME='' notify dev "$dev_commit" passed || status=$?
  [ "$status" = 1 ] && grep -qF 'no SMTP_USERNAME NOTIFY_EMAIL' "$work/out" && ! mailed
}
check "notify.sh: a missing SMTP setting fails (exit 1, naming it) and sends nothing, even when no email is due" \
  missing_setting_fails
notify_refusals() {
  ! notify prod 0.3.0-rc.1 passed && grep -qF 'usage: scripts/notify.sh' "$work/out" \
    && ! notify qa 0.3.0-rc.1 green && grep -qF 'usage: scripts/notify.sh' "$work/out" \
    && ! notify dev main failed && grep -qF 'usage: scripts/notify.sh' "$work/out" && [ ! -s "$CURL_LOG" ]
}
check "notify.sh refuses a version its environment doesn't take, an unknown result and a dev target that isn't a commit" \
  notify_refusals

# Not tested: a QA or prod run superseded by a newer promotion, or cancelled, still reports its target; dev doesn't.
qa_superseded_mailed() {
  DETAIL="eshop-qa is pinned to 0.3.0-rc.2 on main now, not 0.3.0-rc.1" notify qa 0.3.0-rc.1 superseded \
    && [ "$(subject)" = "[eShop] qa v0.3.0-rc.1: NOT TESTED (superseded)" ] \
    && grep -qF "NOT TESTED" "$CURL_MAIL" && grep -qF "eshop-qa is pinned to 0.3.0-rc.2 on main now" "$CURL_MAIL" \
    && ! grep -qF "Rollback" "$CURL_MAIL"
}
check "notify.sh: a superseded QA run is mailed as not tested, saying what QA is pinned to now" qa_superseded_mailed
prod_cancelled_mailed() {
  notify prod 0.3.0 cancelled && [ "$(subject)" = "[eShop] prod v0.3.0: NOT TESTED (cancelled)" ] \
    && grep -qF "e2e/run-on-actions.sh prod 0.3.0" "$CURL_MAIL" && ! grep -qF "Rollback" "$CURL_MAIL"
}
check "notify.sh: a cancelled prod run is mailed as not tested, with how to run it again" prod_cancelled_mailed
dev_not_tested_quiet() {
  notify dev "$dev_commit" superseded && ! mailed && notify dev "$dev_commit" cancelled && ! mailed
}
check "notify.sh: a superseded or cancelled dev run sends nothing" dev_not_tested_quiet

# notify.sh results <dir>: e2e.yml's notify job, every target of the run (stdin) from its smoke-result-<env> artifact.
results_dir=$work/results
smoke_result() { # smoke_result <env> <result line> [detail]: the artifact e2e.yml's test job uploads
  mkdir -p "$results_dir/smoke-result-$1"
  echo "$2" >"$results_dir/smoke-result-$1/result"
  echo "${3:-}" >"$results_dir/smoke-result-$1/detail"
  echo "$run_url/artifacts/98" >"$results_dir/smoke-result-$1/report-url"
}
all_subjects() { sed -n 's/^Subject: //p' "$CURL_MAIL.all" 2>/dev/null | tr -d '\r'; }
mails_each_target() {
  rm -rf "$GH_STATE/deployments" "$results_dir"
  smoke_result qa "failed" "the Playwright demo failed"
  smoke_result prod "passed"
  printf 'qa 0.3.1-rc.1\nprod 0.3.0\n' | notify results "$results_dir" \
    && [ "$(all_subjects)" = "$(printf '%s\n' "[eShop] qa v0.3.1-rc.1: smoke test FAILED" \
         "[eShop] prod v0.3.0: deployed and smoke test passed")" ] \
    && grep -qF "the Playwright demo failed" "$CURL_MAIL.all" && grep -qF "$run_url/artifacts/98" "$CURL_MAIL.all"
}
check "notify.sh results <dir>: each target of the run is mailed from its result, detail and report link" mails_each_target
missing_result_not_tested() {
  rm -rf "$GH_STATE/deployments" "$results_dir"; mkdir -p "$results_dir"
  printf 'qa 0.3.1-rc.1\ndev %s\n' "$dev_commit" | notify results "$results_dir" \
    && [ "$(all_subjects)" = "[eShop] qa v0.3.1-rc.1: NOT TESTED (cancelled)" ] \
    && grep -qF "recorded no result" "$CURL_MAIL.all" && ! grep -qF FAILED "$CURL_MAIL.all"
}
check "notify.sh results <dir>: a target with no result (its job cancelled while queued) is not tested, never FAILED: QA mailed as such, dev not at all" \
  missing_result_not_tested
one_email_failing_fails() {
  rm -rf "$GH_STATE/deployments" "$results_dir"
  smoke_result qa "passed"; smoke_result prod "passed"
  local status=0
  printf 'qa 0.3.1-rc.1\nprod 0.3.0\n' | NOTIFY_EMAIL='' notify results "$results_dir" || status=$?
  [ "$status" = 1 ] && [ "$(grep -c 'no NOTIFY_EMAIL' "$work/out")" = 2 ]
}
check "notify.sh results <dir>: an email that can't be sent fails the whole (exit 1) after trying every target" \
  one_email_failing_fails
rm -rf "$GH_STATE/deployments"

# --- scripts/protect-main.sh (main's ruleset and the release environment; applied by a maintainer) ---

repo_api=repos/pkhamdee/eshop-infra
web_api=repos/pkhamdee/eshop-web
# eshop-web's CI on its main, as GitHub serves it: a lint job, and the shared gates (service-image.yml) after it.
export FAKE_CONTENTS="$work/contents"
mkdir -p "$FAKE_CONTENTS/pkhamdee/eshop-web/contents/.github/workflows"
cat >"$FAKE_CONTENTS/pkhamdee/eshop-web/contents/.github/workflows/ci.yml" <<'YAML'
name: CI
on: [push, pull_request]
jobs:
  lint:
    name: eshop-web (lint, build)
    runs-on: ubuntu-latest
    steps:
      - run: npm run lint
  image:
    name: image
    needs: [lint]
    uses: pkhamdee/eshop-infra/.github/workflows/service-image.yml@main
    with:
      images: '[{"service": "eshop-web", "context": ".", "dockerfile": "Dockerfile"}]'
    secrets: inherit
  later:
    needs: [image]
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
for svc_repo in eshop-api eshop-node-api thirdparty-mock; do # their CI: the same shape, their own lint job
  mkdir -p "$FAKE_CONTENTS/pkhamdee/$svc_repo/contents/.github/workflows"
  sed "s/eshop-web/$svc_repo/g" "$FAKE_CONTENTS/pkhamdee/eshop-web/contents/.github/workflows/ci.yml" \
    >"$FAKE_CONTENTS/pkhamdee/$svc_repo/contents/.github/workflows/ci.yml"
done
protect() { (cd "$root" && scripts/protect-main.sh "$@") >"$work/out" 2>&1; }
# sent <METHOD path>: the JSON bodies printed under that request in a --dry-run's output, as a JSON array
sent() { awk -v h="$1" '$0 == h { on = 1; next } /^[^ {}[\]]/ { on = 0 } on' "$work/out" | jq -s .; }
writes() { grep -c -- ' --method ' "$GH_LOG" || true; }
# The required checks: every job a pull request runs in ci-release.yml, by its name (the check's context).
required_checks='[
  "SAST (Semgrep, fail on ERROR)",
  "dependency scan (Trivy, fail on critical)",
  "repo rules (manifests, workflows, scripts, e2e)"
]'
# The tag rulesets: v* tags never deleted, moved or force-pushed by anyone; created only by admins (repository role
# 5) and maintainers (2). Separate, since a bypass actor bypasses every rule of its ruleset.
tag_rulesets='[
  {"name": "Create release tags", "target": "tag", "enforcement": "active",
   "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
   "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"},
                     {"actor_id": 2, "actor_type": "RepositoryRole", "bypass_mode": "always"}],
   "rules": [{"type": "creation"}]},
  {"name": "Protect release tags", "target": "tag", "enforcement": "active",
   "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
   "bypass_actors": [],
   "rules": [{"type": "deletion"}, {"type": "update"}, {"type": "non_fast_forward"}]}
]'

dry_run_prints_and_changes_nothing() {
  rm -f "$GH_STATE"/*; : >"$GH_LOG"
  FAKE_NO_ENVIRONMENT=1 protect --dry-run || return 1
  local ruleset env policies
  ruleset=$(sent "POST $repo_api/rulesets"); env=$(sent "PUT $repo_api/environments/release")
  policies=$(sent "POST $repo_api/environments/release/deployment-branch-policies")
  [ "$(writes)" = 0 ] && [ -z "$(ls "$GH_STATE")" ] \
    && jq -e --argjson tags "$tag_rulesets" '[.[] | select(.target == "tag")] | sort_by(.name) == $tags' \
      <<<"$ruleset" >/dev/null \
    && jq -e --argjson checks "$required_checks" '[.[] | select(.target == "branch")] | length == 1 and (.[0] |
         .name == "Protect main" and .target == "branch" and .enforcement == "active"
         and .conditions.ref_name.include == ["refs/heads/main"]
         and .bypass_actors == [{"actor_id": null, "actor_type": "DeployKey", "bypass_mode": "always"}]
         and ([.rules[].type] | sort) == ["deletion", "non_fast_forward", "pull_request", "required_status_checks"]
         and (.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count == 0
              and .parameters.dismiss_stale_reviews_on_push == false and .parameters.require_last_push_approval == false)
         and (.rules[] | select(.type == "required_status_checks") | .parameters
              | ([.required_status_checks[].context] | sort) == $checks
              and all(.required_status_checks[]; .integration_id == 15368)))' <<<"$ruleset" >/dev/null \
    && jq -e '. == [{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}]' \
      <<<"$env" >/dev/null \
    && jq -e 'sort_by(.name) == [{"name": "main", "type": "branch"}, {"name": "v*", "type": "tag"}]' \
      <<<"$policies" >/dev/null
}
check "protect-main.sh --dry-run prints main's ruleset (every PR check required, 0 approvals, Flux's deploy key bypasses), the tag rulesets (v* immutable, created by admins and maintainers only) and the release environment (main and v* tags only), sending nothing" \
  dry_run_prints_and_changes_nothing

applies_idempotently() {
  rm -f "$GH_STATE"/*; : >"$GH_LOG"
  FAKE_RULESETS='[{"id":7,"name":"Protect release tags","target":"tag"},{"id":42,"name":"Protect main","target":"branch"}]' \
  FAKE_BRANCH_POLICIES='{"total_count":2,"branch_policies":[{"id":1,"name":"main","type":"branch"},{"id":9,"name":"release/*","type":"branch"}]}' \
    protect || return 1
  local s="$GH_STATE/api"
  jq -e '.name == "Protect main"' "$s-PUT-${repo_api//\//_}_rulesets_42" >/dev/null \
    && jq -e '.name == "Protect release tags" and ([.rules[].type] == ["deletion", "update", "non_fast_forward"])
              and .bypass_actors == []' "$s-PUT-${repo_api//\//_}_rulesets_7" >/dev/null \
    && [ "$(grep -c "api $repo_api/rulesets --method POST" "$GH_LOG")" = 1 ] \
    && jq -e '.name == "Create release tags" and .rules == [{"type": "creation"}]' \
      "$s-POST-${repo_api//\//_}_rulesets" >/dev/null \
    && [ -e "$s-PUT-${repo_api//\//_}_environments_release" ] \
    && [ "$(grep -c "api $repo_api/environments/release/deployment-branch-policies --method POST" "$GH_LOG")" = 1 ] \
    && jq -e '. == {"name": "v*", "type": "tag"}' \
      "$s-POST-${repo_api//\//_}_environments_release_deployment-branch-policies" >/dev/null \
    && [ -e "$s-DELETE-${repo_api//\//_}_environments_release_deployment-branch-policies_9" ] \
    && [ ! -e "$s-DELETE-${repo_api//\//_}_environments_release_deployment-branch-policies_1" ]
}
check "protect-main.sh updates existing rulesets in place (release tags keep their rules), creates a missing one and leaves the environment exactly main and v* tags" \
  applies_idempotently

two_approvals() {
  protect --dry-run --approvals 2 \
    && sent "POST $repo_api/rulesets" | jq -e '.[0].rules[] | select(.type == "pull_request") | .parameters
         | .required_approving_review_count == 2 and .dismiss_stale_reviews_on_push == true
           and .require_last_push_approval == true' >/dev/null
}
check "protect-main.sh --approvals 2 requires two approvals, dismisses stale ones and the last push's approval" \
  two_approvals
bad_approvals_refused() {
  : >"$GH_LOG"; ! protect --approvals two && grep -qF 'usage: scripts/protect-main.sh' "$work/out" && [ ! -s "$GH_LOG" ]
}
check "protect-main.sh refuses a malformed --approvals and calls nothing" bad_approvals_refused

# --- scripts/protect-main.sh: the smoke-test environment (SMTP_PASSWORD for e2e.yml's notify job) ---

smoke_test_environment_dry_run() {
  rm -f "$GH_STATE"/*; : >"$GH_LOG"
  FAKE_NO_ENVIRONMENT=1 protect --dry-run || return 1
  [ "$(writes)" = 0 ] \
    && sent "PUT $repo_api/environments/smoke-test" \
      | jq -e '. == [{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}]' >/dev/null \
    && sent "POST $repo_api/environments/smoke-test/deployment-branch-policies" \
      | jq -e '. == [{"name": "main", "type": "branch"}]' >/dev/null
}
check "protect-main.sh --dry-run prints the smoke-test environment, deployable from main only, sending nothing" \
  smoke_test_environment_dry_run
smoke_test_environment_applied() {
  rm -f "$GH_STATE"/*; : >"$GH_LOG"
  FAKE_BRANCH_POLICIES='{"total_count":2,"branch_policies":[{"id":1,"name":"main","type":"branch"},{"id":9,"name":"release/*","type":"branch"}]}' \
    protect || return 1
  local s="$GH_STATE/api-" p=${repo_api//\//_}_environments_smoke-test
  [ -e "${s}PUT-$p" ] \
    && ! grep -qF "api $repo_api/environments/smoke-test/deployment-branch-policies --method POST" "$GH_LOG" \
    && [ -e "${s}DELETE-${p}_deployment-branch-policies_9" ] && [ ! -e "${s}DELETE-${p}_deployment-branch-policies_1" ]
}
check "protect-main.sh leaves the smoke-test environment exactly main (keeps main, removes any other policy)" \
  smoke_test_environment_applied

# --- scripts/protect-main.sh: the service repositories (ADR 0009) ---

service_repo_dry_run() {
  rm -f "$GH_STATE"/*; : >"$GH_LOG"
  FAKE_NO_ENVIRONMENT=1 protect --dry-run || return 1
  [ "$(writes)" = 0 ] \
    && sent "POST $web_api/rulesets" | jq -e 'length == 1 and (.[0] | .name == "Protect main" and .bypass_actors == []
         and .conditions.ref_name.include == ["refs/heads/main"]
         and (.rules[] | select(.type == "required_status_checks") | [.parameters.required_status_checks[].context] | sort)
             == ["eshop-web (lint, build)", "image / SAST (Semgrep, fail on ERROR)",
                 "image / dependency scan (Trivy, fail on critical)"])' >/dev/null \
    && sent "POST $web_api/environments/publish/deployment-branch-policies" \
      | jq -e 'sort_by(.name) == [{"name": "main", "type": "branch"}, {"name": "release/*", "type": "branch"}]' >/dev/null \
    && sent "PATCH $web_api" | jq -e '. == [{"has_issues": false}]' >/dev/null \
    && grep -qF 'image / SAST (Semgrep, fail on ERROR)' "$work/out"
}
check "protect-main.sh --dry-run prints each service repository's main ruleset (its CI's PR jobs and the shared gates' as required checks, no bypass), its publish environment (main and release/* only) and issues off" \
  service_repo_dry_run
service_repo_applied() {
  rm -f "$GH_STATE"/*; : >"$GH_LOG"
  FAKE_BRANCH_POLICIES='{"total_count":2,"branch_policies":[{"id":1,"name":"main","type":"branch"},{"id":9,"name":"v*","type":"tag"}]}' \
    protect || return 1
  local s="$GH_STATE/api-" p=${web_api//\//_}
  [ -e "${s}POST-${p}_rulesets" ] && [ -e "${s}PUT-${p}_environments_publish" ] \
    && jq -e '. == {"name": "release/*", "type": "branch"}' "${s}POST-${p}_environments_publish_deployment-branch-policies" >/dev/null \
    && [ -e "${s}DELETE-${p}_environments_publish_deployment-branch-policies_9" ] \
    && jq -e '. == {"has_issues": false}' "${s}PATCH-$p" >/dev/null
}
check "protect-main.sh applies each service repository's ruleset, leaves its publish environment exactly main and release/*, and turns its issues off" \
  service_repo_applied
service_repo_missing_refused() {
  rm -f "$GH_STATE"/*; : >"$GH_LOG"
  rm -rf "$work/some-contents" && cp -R "$FAKE_CONTENTS" "$work/some-contents" \
    && rm -rf "$work/some-contents/pkhamdee/thirdparty-mock" || return 1
  ! FAKE_CONTENTS="$work/some-contents" protect \
    && grep -qF 'pkhamdee/thirdparty-mock has no .github/workflows/ci.yml on main' "$work/out" && [ "$(writes)" = 0 ]
}
check "protect-main.sh sends nothing at all while any service repository has no CI on GitHub yet (the others ready)" service_repo_missing_refused

# --- scripts/clone-all.sh (the service repositories beside this one) ---

clone_all() { (cd "$1" && CLONE_BASE_URL="$work/hosted" scripts/clone-all.sh) >"$work/out" 2>&1; }
clones_service_repos() {
  local parent="$work/side-by-side"
  mkdir -p "$parent/infra/.github" && cp -R "$root/scripts" "$parent/infra/" && cp "$root/.github/services.json" "$parent/infra/.github/"
  clone_all "$parent/infra" && grep -qF "eshop-web: skipped, $work/hosted/pkhamdee/eshop-web doesn't exist yet" "$work/out" \
    && [ ! -e "$parent/eshop-web" ] || return 1
  git init -q --bare -b main "$work/hosted/pkhamdee/eshop-web"
  git clone -q "$work/hosted/pkhamdee/eshop-web" "$work/web-seed" 2>/dev/null
  git -C "$work/web-seed" commit -q --allow-empty -m "eshop-web" && git -C "$work/web-seed" push -q origin HEAD:main
  clone_all "$parent/infra" && [ "$(git -C "$parent/eshop-web" log -1 --format=%s)" = eshop-web ] \
    && clone_all "$parent/infra" && grep -qF "eshop-web: already cloned at $parent/eshop-web" "$work/out"
}
check "clone-all.sh skips a service repository not created yet, clones it beside this one once it exists, and leaves the clone alone after" \
  clones_service_repos

# --- scripts/gates/artifact-dirs.sh (the image pipeline's downloads: one folder per artifact) ---

artifact_dirs_normalizes() {
  local d="$work/artifacts"
  rm -rf "$d" && mkdir -p "$d/flat" "$d/many/image-eshop-api"
  printf 'docker.io/pkhamdee/eshop-web:main-abc1234\ndocker.io/pkhamdee/eshop-web:main-abc1234-100\n' >"$d/flat/tags.txt"
  echo tar >"$d/flat/image.tar"
  echo tags >"$d/many/image-eshop-api/tags.txt"
  "$root/scripts/gates/artifact-dirs.sh" "$d/flat" >"$work/out" 2>&1 \
    && "$root/scripts/gates/artifact-dirs.sh" "$d/many" >>"$work/out" 2>&1 \
    && [ -f "$d/flat/image-eshop-web/image.tar" ] && [ -f "$d/flat/image-eshop-web/tags.txt" ] \
    && [ ! -e "$d/flat/tags.txt" ] && [ "$(ls "$d/many")" = image-eshop-api ]
}
check "artifact-dirs.sh moves a single flat image artifact into image-<service> and leaves per-artifact folders alone" \
  artifact_dirs_normalizes

# --- scripts/gates/tags-to-push.sh (service-image.yml's push: never overwrite a tag) ---

tags_dir="$work/tags-to-push"
tags_file() { mkdir -p "$tags_dir/$1" && printf '%s\n' "${@:2}" >"$tags_dir/$1/tags.txt"; }
to_push() { "$root/scripts/gates/tags-to-push.sh" "$tags_dir"/*/tags.txt >"$work/out" 2>"$work/err"; }
rm -rf "$REGISTRY/docker.io/pkhamdee/svc-a" "$REGISTRY/docker.io/pkhamdee/svc-b" "$REGISTRY/docker.io/pkhamdee/svc-c"
put_image svc-a main-aaaaaaa-100 sha256:a-old && put_image svc-a main-aaaaaaa sha256:a-old
put_image svc-b main-0000000-50 sha256:b-old
tags_file svc-a docker.io/pkhamdee/svc-a:main-aaaaaaa docker.io/pkhamdee/svc-a:main-aaaaaaa-100
tags_file svc-b docker.io/pkhamdee/svc-b:main-bbbbbbb docker.io/pkhamdee/svc-b:main-bbbbbbb-200
tags_file svc-c docker.io/pkhamdee/svc-c:release-0.x-ccccccc-300
pushes_only_new() {
  to_push && [ "$(cat "$work/out")" = "docker.io/pkhamdee/svc-b:main-bbbbbbb
docker.io/pkhamdee/svc-b:main-bbbbbbb-200
docker.io/pkhamdee/svc-c:release-0.x-ccccccc-300" ] \
    && grep -qF 'skipped docker.io/pkhamdee/svc-a:main-aaaaaaa docker.io/pkhamdee/svc-a:main-aaaaaaa-100' "$work/err"
}
check "tags-to-push.sh: a commit's image already pushed is skipped; new ones (and a repository not created yet) are pushed" \
  pushes_only_new
one_tag_existing_skips_image() {
  rm -rf "$REGISTRY/docker.io/pkhamdee/svc-a" && put_image svc-a main-aaaaaaa-100 sha256:a-old
  to_push && ! grep -q svc-a "$work/out" && grep -qF 'main-aaaaaaa-100 already exists' "$work/err"
}
check "tags-to-push.sh: when any tag of an image exists, none of its tags is pushed" one_tag_existing_skips_image
unreadable_registry_fails() {
  ! FAKE_CRANE_LS_ERROR=1 to_push && grep -qF "could not list the tags of docker.io/pkhamdee/svc-a" "$work/err"
}
check "tags-to-push.sh fails when the registry can't be read (unknown is not absent)" unreadable_registry_fails

# --- scripts/gates/attach-sbom.sh (the push jobs: each pushed image's SBOM as a referrer of its digest, ADR 0010) ---

export REGISTRY="$work/attach-sbom/registry"
sbom_dir="$work/attach-sbom/sbom"
mkdir -p "$sbom_dir" && echo '{"bomFormat":"CycloneDX","from":"this run"}' >"$sbom_dir/svc-a.cdx.json"
# The generator for an earlier build: records its argument, writes <repository>.cdx.json as sbom.sh does.
cat >"$work/attach-sbom/generator" <<'GEN'
#!/usr/bin/env bash
echo "$1" >>"$GENERATOR_LOG"; repository=${1%@*}
echo '{"bomFormat":"CycloneDX","from":"registry"}' >"$REPORT_DIR/${repository##*/}.cdx.json"
GEN
chmod +x "$work/attach-sbom/generator"
export SBOM_GENERATOR="$work/attach-sbom/generator" GENERATOR_LOG="$work/attach-sbom/generator.log"
attach() { : >"$ORAS_LOG"; : >"$GENERATOR_LOG"; "$root/scripts/gates/attach-sbom.sh" "$@" "$sbom_dir/svc-a.cdx.json" >"$work/out" 2>&1; }
referrer() { cat "$REGISTRY/.referrers/$1/svc-a.cdx.json" 2>/dev/null; }
put_image svc-a main-aaaaaaa-100 sha256:a1
attaches_to_digest() {
  attach docker.io/pkhamdee/svc-a:main-aaaaaaa-100 && grep -qF '"this run"' <(referrer sha256:a1) \
    && grep -qF 'oras attach --artifact-type application/vnd.cyclonedx+json docker.io/pkhamdee/svc-a@sha256:a1 svc-a.cdx.json:application/vnd.cyclonedx+json' "$ORAS_LOG"
}
check "attach-sbom.sh attaches the SBOM to the digest the tag names, titled by its file name" attaches_to_digest
keeps_existing() {
  echo '{"bomFormat":"CycloneDX","from":"first run"}' >"$REGISTRY/.referrers/sha256:a1/svc-a.cdx.json"
  attach docker.io/pkhamdee/svc-a:main-aaaaaaa-100 && ! grep -q 'oras attach' "$ORAS_LOG" \
    && grep -qF '"first run"' <(referrer sha256:a1) && grep -qF 'already has an SBOM: kept' "$work/out"
}
check "attach-sbom.sh never replaces an SBOM the digest already has" keeps_existing
put_image svc-a main-bbbbbbb-200 sha256:b1
earlier_build_regenerates() {
  attach --earlier-build docker.io/pkhamdee/svc-a:main-bbbbbbb-200 \
    && [ "$(cat "$GENERATOR_LOG")" = docker.io/pkhamdee/svc-a@sha256:b1 ] && grep -qF '"registry"' <(referrer sha256:b1)
}
check "attach-sbom.sh --earlier-build makes the SBOM from the registry digest, not from this run's rebuild" \
  earlier_build_regenerates
earlier_build_kept() {
  attach --earlier-build docker.io/pkhamdee/svc-a:main-aaaaaaa-100 && [ ! -s "$GENERATOR_LOG" ] \
    && ! grep -q 'oras attach' "$ORAS_LOG"
}
check "attach-sbom.sh --earlier-build keeps an earlier build's SBOM without making another" earlier_build_kept
put_image svc-a main-ccccccc-300 sha256:c1
unknown_referrers_fail() {
  ! FAKE_ORAS_DISCOVER_ERROR=1 attach docker.io/pkhamdee/svc-a:main-ccccccc-300 \
    && grep -qF "can't tell whether it has an SBOM" "$work/out" && [ -z "$(referrer sha256:c1)" ]
}
check "attach-sbom.sh fails when the referrers can't be read (unknown is not absent)" unknown_referrers_fail
attach_failure_fails() { ! FAKE_ORAS_ATTACH_ERROR=1 attach docker.io/pkhamdee/svc-a:main-ccccccc-300; }
check "attach-sbom.sh fails when the attach fails" attach_failure_fails
missing_image_fails() {
  ! attach docker.io/pkhamdee/svc-a:main-0000000-1 && grep -qF 'could not read the digest' "$work/out" \
    && ! grep -q 'oras attach' "$ORAS_LOG"
}
check "attach-sbom.sh fails when the tag doesn't exist" missing_image_fails

# --- scripts/gates/sign-images.sh (service-image.yml's push job: sign only the digests this run pushed, ADR 0011) ---

pushed="$work/sign-images/pushed.txt"
mkdir -p "$work/sign-images"
da=sha256:$(printf 'a%.0s' $(seq 64)) db=sha256:$(printf 'b%.0s' $(seq 64))
sign() { : >"$COSIGN_LOG"; "$root/scripts/gates/sign-images.sh" "$pushed" >"$work/out" 2>&1; }
signs_each_digest_once() {
  printf '%s\n' "docker.io/pkhamdee/svc-a@$da" "docker.io/pkhamdee/svc-a@$da" "docker.io/pkhamdee/svc-b@$db" >"$pushed"
  sign && [ "$(cat "$COSIGN_LOG")" = "cosign sign --yes docker.io/pkhamdee/svc-a@$da
cosign sign --yes docker.io/pkhamdee/svc-b@$db" ]
}
check "sign-images.sh signs each pushed digest once (an image's two tags share it), by digest" signs_each_digest_once
nothing_pushed_signs_nothing() { : >"$pushed"; sign && [ ! -s "$COSIGN_LOG" ] && grep -qF 'nothing to sign' "$work/out"; }
check "sign-images.sh signs nothing when the run pushed nothing (a re-run never signs an existing image)" \
  nothing_pushed_signs_nothing
tag_refused() {
  printf '%s\n' docker.io/pkhamdee/svc-a:main-aaaaaaa-100 "docker.io/pkhamdee/svc-b@$db" >"$pushed"
  ! sign && ! grep -qF 'svc-a' "$COSIGN_LOG" && grep -qF "svc-b@$db" "$COSIGN_LOG" \
    && grep -qF 'not a digest reference, not signed: docker.io/pkhamdee/svc-a:main-aaaaaaa-100' "$work/out"
}
check "sign-images.sh never signs a tag (it can move), signs the rest, and fails" tag_refused
failure_tries_all() {
  printf '%s\n' "docker.io/pkhamdee/svc-a@$da" "docker.io/pkhamdee/svc-b@$db" >"$pushed"
  ! FAKE_COSIGN_FAIL="docker.io/pkhamdee/svc-a@$da" sign && grep -qF "svc-b@$db" "$COSIGN_LOG" \
    && grep -qF 'the fix is a new commit' "$work/out"
}
check "sign-images.sh tries every image when one fails, then fails saying a new commit is the fix" failure_tries_all

# --- scripts/check-enterprise-schema.sh (the deployed mock Enterprise schema is the one the sync master is tested with) ---

schema_check() { (cd "$root" && ENTERPRISE_SCHEMA_SOURCE="$1" scripts/check-enterprise-schema.sh) >"$work/out" 2>&1; }
cp "$root/deploy/thirdparty/mssql/enterprise-schema.sql" "$work/schema-same.sql"
{ cat "$work/schema-same.sql"; echo "ALTER TABLE hp_contract ADD note nvarchar(50);"; } >"$work/schema-changed.sql"
schema_same() { schema_check "$work/schema-same.sql" && grep -qF 'is the schema eshop-sync-master is tested against' "$work/out"; }
check "check-enterprise-schema.sh passes when the deployed schema is eshop-api's" schema_same
schema_differs() {
  ! schema_check "$work/schema-changed.sql" && grep -qF -- '-ALTER TABLE hp_contract' "$work/out" \
    && grep -qF 'copy that one here' "$work/out"
}
check "check-enterprise-schema.sh fails with the difference when eshop-api's schema changed" schema_differs
schema_unreadable() { ! schema_check "$work/no-such.sql" && grep -qF "can't read eshop-api's Enterprise schema" "$work/out"; }
check "check-enterprise-schema.sh fails when eshop-api's schema can't be read" schema_unreadable

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
