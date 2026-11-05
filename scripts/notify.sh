#!/usr/bin/env bash
# Emails a smoke test's result (ADR 0008; e2e.yml's notify job): which environment, what it was testing, how it went,
# and links to the run and its Playwright report.
#
#   scripts/notify.sh results <dir>   <<<"<env> <target> lines"
#       e2e.yml's notify job: every target of the run (the targets job's lines, on stdin), each from its artifact
#       <dir>/smoke-result-<env>/ (the test job's last step): `result` (`<result> [deployment id]`), `detail` (why),
#       `report-url`, `retried.txt`. A target with no result is `cancelled`: its job was cancelled while queued, or
#       died before that step, so nothing says it was tested, and nothing says it failed. Tries every target; exit 1
#       when any email failed
#   scripts/notify.sh <env> <target> <result> [deployment id]
#       one target: <env> <target> a line of scripts/smoke-targets.sh (qa X.Y.Z-rc.N, prod X.Y.Z, or dev <main
#       commit>); <result> as scripts/smoke-result.sh decides it: passed, retried (passed, but only on a retry),
#       failed, not-deployed (the environment never served the target, so nothing was tested), superseded or
#       cancelled (not tested); deployment id the run's Deployment of the target (scripts/deployment.sh), when it got
#       that far: dev and prod look at the Deployments before it
#
# Who gets what:
#   - qa and prod: every result, a not-tested one too (superseded by a newer promotion, or cancelled): every QA and
#     prod target is reported;
#   - dev: a failure (failed or not-deployed), and the first pass after one, judged from dev's previous Deployment
#     with an outcome (success or failure; one superseded or cancelled tested nothing). Any other dev result: no email.
# A prod failure names the last release whose prod Deployment succeeded and how to roll back to it: a promotion PR,
# scripts/promotion-pr.sh prod <version> (its commit is scripts/pin-release.sh prod <version>).
#
# Settings from the environment (e2e.yml: repository variables SMTP_USERNAME and NOTIFY_EMAIL, secret SMTP_PASSWORD
# of environment smoke-test; docs/setup.md, "Smoke test email"):
#   SMTP_USERNAME   the sending account (Gmail), also the From address
#   SMTP_PASSWORD   its app password: handed to curl on stdin (--config -), never on its command line or printed
#   NOTIFY_EMAIL    the recipient; several separated by commas
#   SMTP_URL        default smtps://smtp.gmail.com:465 (TLS from the start; --ssl-reqd refuses anything less)
#   RUN_URL         the run; REPORT_URL the Playwright report artifact (default: the run, which lists it)
#   DETAIL          why it failed or wasn't tested; RETRIED_FILE the tests that passed only on retry (one target)
# A missing setting is an error (exit 1, naming it) checked before anything else, whether or not an email is due:
# the notify step fails visibly. The Deployment is already finished by then, and this never changes it.
# Needs gh with Deployments read access (GITHUB_TOKEN: `deployments: read`), jq and curl.
# Tests: scripts/tests/release-scripts.sh (fake gh and curl: no email is sent).
set -euo pipefail
# shellcheck source=lib/repo.sh
. "$(dirname "$0")/lib/repo.sh"
# shellcheck source=lib/versions.sh
. "$(dirname "$0")/lib/versions.sh"
# shellcheck source=lib/deployments.sh
. "$(dirname "$0")/lib/deployments.sh"

usage() {
  [ $# -eq 0 ] || echo "notify.sh: $*" >&2
  echo "usage: scripts/notify.sh qa X.Y.Z-rc.N | prod X.Y.Z | dev <commit>" \
    " passed|retried|failed|not-deployed|superseded|cancelled [deployment id]   |   scripts/notify.sh results <dir>" >&2
  exit 2
}

if [ "${1:-}" = results ]; then
  [ $# -eq 2 ] || usage
  status=0
  while read -r env target; do
    [ -n "$env" ] || continue
    dir="$2/smoke-result-$env"
    result=cancelled id=
    [ ! -f "$dir/result" ] || read -r result id <"$dir/result"
    detail=$(cat "$dir/detail" 2>/dev/null \
      || echo "the smoke test job recorded no result: it was cancelled before it ran, or died before the end")
    DETAIL=$detail REPORT_URL=$(cat "$dir/report-url" 2>/dev/null || echo "${RUN_URL:-}") \
      RETRIED_FILE="$dir/retried.txt" "$0" "$env" "$target" "$result" ${id:+"$id"} \
      || { status=1; echo "::error::$env $target: the result was not emailed (see above)"; }
  done
  exit "$status"
fi

[[ $# =~ ^[34]$ ]] || usage
env=$1 target=$2 result=$3 id=${4:-}
is_env "$env" || usage "unknown environment '$env'"
is_target "$env" "$target" || usage "$env takes $(env_grammar "$env"), not '$target'"
[[ "$id" =~ ^[0-9]*$ ]] || usage "a Deployment id is a number, not '$id'"

# Each result: the subject's outcome, and the body's line.
case "$result" in
  passed) outcome="deployed and smoke test passed" said="deployed, and the smoke test passed." ;;
  retried) outcome="deployed and smoke test passed on retry"
    said="deployed, and the smoke test passed, but only on a retry." ;;
  failed) outcome="smoke test FAILED" said="the smoke test FAILED${DETAIL:+: $DETAIL}." ;;
  not-deployed) outcome="NOT DEPLOYED, smoke test FAILED" said="NOT DEPLOYED, so not tested${DETAIL:+: $DETAIL}." ;;
  superseded) outcome="NOT TESTED (superseded)"
    said="NOT TESTED: a newer deploy of $env replaced it before its smoke test finished${DETAIL:+ ($DETAIL)}."
    said+=" That deploy's own smoke test reports on it." ;;
  cancelled) outcome="NOT TESTED (cancelled)"
    said="NOT TESTED: the smoke test was cancelled${DETAIL:+ ($DETAIL)}."
    said+=" Test it again: e2e/run-on-actions.sh $env $target" ;;
  *) usage "unknown result '$result'" ;;
esac

missing=()
for setting in SMTP_USERNAME SMTP_PASSWORD NOTIFY_EMAIL; do [ -n "${!setting:-}" ] || missing+=("$setting"); done
if [ ${#missing[@]} -gt 0 ]; then
  echo "notify.sh: no ${missing[*]}: can't email the $env result (docs/setup.md, \"Smoke test email\")" >&2
  exit 1
fi
RUN_URL=${RUN_URL:-}
REPORT_URL=${REPORT_URL:-$RUN_URL}

# last_outcome <env> <state regex> [ref to skip]: the newest Deployment of <env> before this run's whose outcome
# matches, as "<ref> success|failure"; nothing if none. One with no outcome (superseded, cancelled) tested nothing
# and is skipped.
last_outcome() {
  local d ref state
  while read -r d ref _; do
    [ -n "$d" ] || continue
    [ -z "$id" ] || [ "$d" -lt "$id" ] || continue
    [ "$ref" != "${3:-}" ] || continue
    state=$(outcome_of "$d")
    if [ -n "$state" ] && [[ "$state" =~ $2 ]]; then echo "$ref $state"; return; fi
  done < <(deployments_of "$1")
}

case "$result" in passed | retried) passed=true ;; *) passed=false ;; esac
if [ "$env" = dev ]; then
  what="commit ${target:0:7}" name=${target:0:7}
  case "$result" in
    superseded | cancelled)
      echo "dev $result at ${target:0:7}: no email (dev mails failures and the first pass after one)"
      exit 0 ;;
  esac
  if $passed; then
    previous=$(last_outcome dev '^(success|failure)$')
    if [ "${previous##* }" != failure ]; then
      echo "dev passed at ${target:0:7}, as before: no email (dev mails failures and the first pass after one)"
      exit 0
    fi
    recovered=${previous% *}
  fi
else
  what="version v$target" name="v$target"
fi
subject="[eShop] $env $name: $outcome"

message=$(mktemp)
trap 'rm -f "$message"' EXIT
{
  echo "From: $SMTP_USERNAME"
  echo "To: $NOTIFY_EMAIL"
  echo "Subject: $subject"
  echo "Date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
  echo "MIME-Version: 1.0"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo
  echo "Environment: $env"
  echo "Tested: $what${id:+ (Deployment $id)}"
  echo "Result: $said"
  [ -z "${recovered:-}" ] || echo "Dev's previous smoke test, of ${recovered:0:7}, had failed: this is the first pass since."
  echo
  echo "Run: $RUN_URL"
  echo "Playwright report (artifact playwright-report-$env): $REPORT_URL"
  if [ -n "${RETRIED_FILE:-}" ] && [ -s "$RETRIED_FILE" ]; then
    echo
    echo "Passed only on retry (the first failure is in the Playwright report):"
    sed 's/^/- /' "$RETRIED_FILE"
  fi
  if [ "$env" = prod ] && [[ "$result" =~ ^(failed|not-deployed)$ ]]; then
    echo
    last=$(last_outcome prod '^success$' "v$target")
    last=${last% *} last=${last#v}
    if [ -n "$last" ]; then
      echo "Rollback: the last release that passed in prod is v$last. Roll prod back to it with a promotion PR,"
      echo "then merge it (its commit is scripts/pin-release.sh prod $last):"
      echo
      echo "  scripts/promotion-pr.sh prod $last"
    else
      echo "Rollback: no earlier release passed in prod, so there is none to roll back to."
    fi
  fi
} | sed 's/$/\r/' >"$message"

recipients=()
IFS=, read -ra to <<<"$NOTIFY_EMAIL"
for r in "${to[@]}"; do r=${r// /}; [ -z "$r" ] || recipients+=(--mail-rcpt "$r"); done
# The password goes to curl on stdin, never on its command line (which any process on the runner can read); in
# curl's config syntax, inside quotes, with \ and " escaped.
quoted=${SMTP_PASSWORD//\\/\\\\} quoted=${quoted//\"/\\\"}
printf 'user = "%s:%s"\n' "$SMTP_USERNAME" "$quoted" \
  | curl --silent --show-error --fail --ssl-reqd --url "${SMTP_URL:-smtps://smtp.gmail.com:465}" \
      --mail-from "$SMTP_USERNAME" "${recipients[@]}" --config - --upload-file "$message"
echo "emailed $NOTIFY_EMAIL: $subject"
