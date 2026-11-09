#!/usr/bin/env bash
# The watchdog (#152): failures nobody would otherwise be told about. Two checks, each reported by one GitHub issue
# and an email when that issue opens or closes, never once per run.
#
#   scripts/watchdog.sh queue                       # watchdog.yml (GitHub-hosted, every 15 minutes)
#       Prints one line per job of $REPO that waits for the cluster's runner (label eshop-e2e: e2e.yml's smoke test,
#       watchdog-cluster.yml's check) and has been queued longer than $QUEUE_MINUTES (default 30). A runner that
#       can't register (as after the rename, #106) shows up here, from outside the cluster.
#   scripts/watchdog.sh cluster                     # watchdog-cluster.yml, on the cluster's runner (every 30 minutes)
#       Prints one line per Flux Kustomization or HelmRelease not Ready for longer than $NOT_READY_MINUTES (default 15;
#       a suspended one is skipped: suspending is deliberate), and one if policy-controller's webhook has no ready pod:
#       its failurePolicy is Ignore, so while it is down images are admitted unchecked (ADR 0011).
#   scripts/watchdog.sh report <check> <problems file>
#       The check's issue, titled "Watchdog: <check>": with problems and no open issue, opens it and emails; with
#       problems and an open one, updates its body when they changed (no email); without problems and an open one,
#       comments, closes it and emails that it recovered; otherwise nothing.
#
# Environment: REPO (default: scripts/lib/repo.sh), RUN_URL (this run, linked in the issue and the email), NOW (an ISO
# time, for tests; default now), the mail settings of scripts/lib/mail.sh (checked by `report` before anything else).
# Needs gh (queue: actions read; report: issues write), kubectl (cluster: read on Flux's objects and the webhook's
# Deployment, deploy/infrastructure/runners/runner-rbac.yaml) and jq. scripts/tests/release-scripts.sh tests it with
# fake gh, kubectl and curl.
set -euo pipefail
# shellcheck source=lib/repo.sh
. "$(dirname "$0")/lib/repo.sh"
# shellcheck source=lib/mail.sh
. "$(dirname "$0")/lib/mail.sh"

usage() { echo "usage: scripts/watchdog.sh queue | cluster | report <check> <problems file>" >&2; exit 2; }
now() { if [ -n "${NOW:-}" ]; then jq -rn --arg t "$NOW" '$t | fromdateiso8601'; else date -u +%s; fi; }

queue() {
  local limit=${QUEUE_MINUTES:-30} now
  now=$(now)
  for status in queued in_progress; do
    gh_read api "repos/$REPO/actions/runs?status=$status&per_page=100" --jq '.workflow_runs[].id'
  done | sort -u | while read -r run; do
    [ -n "$run" ] || continue
    gh_read api "repos/$REPO/actions/runs/$run/jobs?per_page=100" | jq -r --argjson now "$now" --argjson limit "$limit" '
      .jobs[] | select(.status == "queued" and (.labels | index("eshop-e2e")))
      | (($now - (.created_at | fromdateiso8601)) / 60 | floor) as $m | select($m >= $limit)
      | "Job \"\(.name)\" has waited \($m) minutes for the cluster'"'"'s runner (eshop-e2e): \(.html_url)"'
  done
}

cluster() {
  local limit=${NOT_READY_MINUTES:-15} now kind ready
  now=$(now)
  for kind in kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io; do
    kubectl get "$kind" --all-namespaces -o json | jq -r --argjson now "$now" --argjson limit "$limit" '
      .items[] | select((.spec.suspend // false) | not)
      | (.status.conditions // [] | map(select(.type == "Ready")) | first) as $r
      | select($r == null or $r.status != "True")
      | (if $r == null then $limit else (($now - ($r.lastTransitionTime | fromdateiso8601)) / 60 | floor) end) as $m
      | select($m >= $limit)
      | "\(.kind) \(.metadata.namespace)/\(.metadata.name) not Ready for \($m) minutes: \($r.reason // "no status"): \(($r.message // "") | .[0:200])"'
  done
  ready=$(kubectl -n cosign-system get deployment policy-controller-webhook -o jsonpath='{.status.readyReplicas}')
  if [ "${ready:-0}" -lt 1 ]; then
    echo "policy-controller's webhook (cosign-system/policy-controller-webhook) has no ready pod: images are admitted unchecked until it is back"
  fi
}

report() {
  [ $# -eq 2 ] || usage
  local check=$1 problems=$2 title missing open body
  [ -f "$problems" ] || { echo "no problems file $problems" >&2; exit 2; }
  missing=$(mail_missing)
  [ -z "$missing" ] || { echo "watchdog: no $missing: can't email (docs/setup.md, \"Smoke test email\")" >&2; exit 1; }
  title="Watchdog: $check"
  open=$(gh issue list --repo "$REPO" --state open --search "in:title \"$title\"" --json number,title,body \
    --jq "map(select(.title == \"$title\")) | first // empty")
  body=$(mktemp) && trap 'rm -f "$body"' RETURN
  if [ -s "$problems" ]; then
    {
      echo "The watchdog found this${RUN_URL:+ ([run]($RUN_URL))}. It closes this issue by itself once it's fixed."
      echo
      sed 's/^/- /' "$problems"
      echo
      echo "What to do: docs/setup.md, \"Watchdog\"."
    } >"$body"
    if [ -z "$open" ]; then
      url=$(gh issue create --repo "$REPO" --title "$title" --body-file "$body")
      { cat "$problems"; echo; echo "Issue: $url"; [ -z "${RUN_URL:-}" ] || echo "Run: $RUN_URL"; } >"$body.mail"
      mail_send "[eShop] watchdog: $check needs attention" "$body.mail"
      rm -f "$body.mail"
      echo "opened $url and emailed $NOTIFY_EMAIL"
    elif [ "$(jq -r .body <<<"$open" | sed -n '/^- /p')" != "$(sed 's/^/- /' "$problems")" ]; then
      gh issue edit "$(jq -r .number <<<"$open")" --repo "$REPO" --body-file "$body" >/dev/null
      echo "updated #$(jq -r .number <<<"$open"): the problems changed"
    else
      echo "#$(jq -r .number <<<"$open") already open: same problems"
    fi
  elif [ -n "$open" ]; then
    n=$(jq -r .number <<<"$open")
    gh issue comment "$n" --repo "$REPO" --body "Recovered: the watchdog found nothing wrong${RUN_URL:+ ([run]($RUN_URL))}." >/dev/null
    gh issue close "$n" --repo "$REPO" >/dev/null
    { echo "Nothing is wrong any more: closed #$n."; [ -z "${RUN_URL:-}" ] || echo "Run: $RUN_URL"; } >"$body"
    mail_send "[eShop] watchdog: $check recovered" "$body"
    echo "closed #$n and emailed $NOTIFY_EMAIL"
  else
    echo "watchdog $check: nothing wrong"
  fi
}

case "${1:-}" in
  queue) [ $# -eq 1 ] || usage; queue ;;
  cluster) [ $# -eq 1 ] || usage; cluster ;;
  report) shift; report "$@" ;;
  *) usage ;;
esac
