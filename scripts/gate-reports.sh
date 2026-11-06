#!/usr/bin/env bash
# The gate reports behind a release candidate's images (docs/git-workflow.md, "2. CI makes its images" and
# "5. Sign-off"): for each image, the CI run that pushed it and that run's Locust and ZAP reports, one Markdown list
# item per image. CI's QA promotion PR (ci-release.yml) and the sign-off record (scripts/sign-off-pr.sh) list them.
#
#   scripts/gate-reports.sh docker.io/pkhamdee/eshop-api:0.6.0-rc.1@sha256:… …
#   # - eshop-api, built from `c26726e` in pkhamdee/eshop-api: [CI run](…), Locust [perf-report](…/artifacts/…), ZAP [dast-report](…/artifacts/…)
#
# Where an image comes from: the commit in its org.opencontainers.image.revision label (CI sets it) and its service's
# `repository` in .github/services.json ($REPO for a service built here). Its run is that commit's first run, by
# creation, whose push job ("push images") succeeded: a run that failed a gate pushed nothing, and a later run of the
# same commit pushes nothing either (scripts/gates/tags-to-push.sh), so that run's reports are of the gates this image
# passed. A patch image (release-N.x-<sha>-<ts>) and an image carried over from an earlier release resolve the same
# way, to the run that first built them.
#
# Never fails for what it can't find: an image without the label, a commit with no run that pushed, a report that is
# missing or expired (GitHub keeps artifacts 90 days by default) and runs it can't read are each said on that image's
# line, so the promotion and the sign-off go on. Exits 2 only for a malformed argument.
#
# Environment: REPO (scripts/lib/repo.sh), SIGN_OFF_READ_TOKEN (gh_read: the reads). Needs crane (the label; reads
# only), gh and jq. scripts/tests/release-scripts.sh tests it with fake gh and crane.
set -euo pipefail
# shellcheck source=lib/repo.sh
. "$(dirname "$0")/lib/repo.sh"

cd "$(git rev-parse --show-toplevel)"
[ $# -gt 0 ] || { echo "usage: scripts/gate-reports.sh <repository>[:<tag>]@sha256:<digest>..." >&2; exit 2; }
for image in "$@"; do
  [[ "$image" =~ ^[^@[:space:]]+@sha256:[0-9a-f]+$ ]] \
    || { echo "not an image with its digest (<repository>[:<tag>]@sha256:<digest>): '$image'" >&2; exit 2; }
done

# The reports the shared gates keep (service-image.yml's and ci-release.yml's gate job), as <artifact>:<tool>.
reports="perf-report:Locust dast-report:ZAP"

for image in "$@"; do
  ref=${image%@*} digest=${image#*@}
  repository=$ref
  [[ "${ref##*/}" != *:* ]] || repository=${ref%:*} # drop the tag
  svc=${repository##*/}
  repo=$(jq -r --arg s "$svc" 'first(.[] | select(.service == $s) | .repository // empty) // empty' .github/services.json)
  repo=${repo:-$REPO}

  revision=$(crane config "$repository@$digest" 2>/dev/null \
    | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' 2>/dev/null) || revision=""
  if [ -z "$revision" ]; then
    echo "- $svc: no source commit (the image has no org.opencontainers.image.revision label), so its gate reports can't be found"
    continue
  fi
  line="- $svc, built from \`${revision:0:7}\` in $repo"

  # The commit's runs, oldest first (a pull request's runs are of a merge commit, never this one's push).
  if ! runs=$(gh_read api "repos/$repo/actions/runs?head_sha=$revision&per_page=100" \
    --jq '[.workflow_runs[] | select(.event != "pull_request")] | sort_by(.created_at) | .[] | "\(.id) \(.html_url)"'); then
    echo "$line: could not read its CI runs"
    continue
  fi
  run="" url=""
  while read -r id html; do
    [ -n "$id" ] || continue
    pushed=$(gh_read api "repos/$repo/actions/runs/$id/jobs?per_page=100" \
      --jq '[.jobs[] | select((.name == "push images" or (.name | endswith(" / push images"))) and .conclusion == "success")] | length') \
      || pushed=0
    if [ "${pushed:-0}" -gt 0 ]; then run=$id url=$html; break; fi
  done <<<"$runs"
  if [ -z "$run" ]; then
    echo "$line: no CI run of that commit pushed it, so its gate reports can't be found"
    continue
  fi

  line+=": [CI run]($url)"
  artifacts=$(gh_read api "repos/$repo/actions/runs/$run/artifacts?per_page=100") || artifacts=""
  for report in $reports; do
    name=${report%%:*} tool=${report#*:}
    if [ -z "$artifacts" ]; then line+=", $tool $name: could not read the run's artifacts"; continue; fi
    # A re-run attempt uploads its own: the newest is the attempt that pushed.
    read -r id expired < <(jq -r --arg n "$name" \
      '[.artifacts[] | select(.name == $n)] | sort_by(.created_at) | last | if . == null then "" else "\(.id) \(.expired)" end' \
      <<<"$artifacts")
    if [ -z "$id" ]; then line+=", $tool $name not found in the run"
    elif [ "$expired" = true ]; then line+=", $tool $name expired"
    else line+=", $tool [$name]($url/artifacts/$id)"; fi
  done
  echo "$line"
done
