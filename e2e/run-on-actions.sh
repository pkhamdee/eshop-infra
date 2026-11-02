#!/usr/bin/env bash
# Run the E2E smoke test (.github/workflows/e2e.yml) on GitHub Actions, on the runner inside the cluster.
#
#   e2e/run-on-actions.sh qa 0.3.0-rc.1        # QA's test of candidate 0.3.0-rc.1 again (a pass opens its sign-off PR)
#   e2e/run-on-actions.sh                       # eshop-prod at its pin on main: https://prod.eshop.localhost
#   e2e/run-on-actions.sh prod 0.2.0            # eshop-prod, refusing unless it serves 0.2.0
#   e2e/run-on-actions.sh dev                   # eshop-dev at main's head: https://eshop.localhost
#
# Given a version, it first checks here that the environment serves it (e2e/check-serving.sh) and stops before
# dispatching anything if not; the job waits for it, checks again after the test and records a Deployment, as an
# automatic run does. The run is named `E2E <environment>[ <version>]` (e.g. `E2E qa 0.3.0-rc.1`); sign-off goes by
# QA's Deployment, which a run from main records like an automatic one.
#
# The job runs on the cluster's own runner, the Actions Runner Controller scale set `eshop-e2e`
# (deploy/ci-runners, ADR 0008), which starts one runner pod for the job and removes it afterwards. This script
# only dispatches the workflow from main and follows the run; nothing is registered on this machine.
# Tests: e2e/run-on-actions.test.sh.
#
# Needs: gh (logged in, write access); for a version, kubectl pointed at the cluster and jq (the check here).
set -euo pipefail
# shellcheck source=../scripts/lib/repo.sh
. "$(dirname "$0")/../scripts/lib/repo.sh"

ENVIRONMENT=${1:-prod}
VERSION=${2:-}

case "$ENVIRONMENT" in
  qa) [ -n "$VERSION" ] || { echo "a QA run needs the release candidate QA serves: e2e/run-on-actions.sh qa X.Y.Z-rc.N" >&2; exit 2; } ;;
  prod | dev) ;;
  *) echo "usage: e2e/run-on-actions.sh [prod|qa|dev] [version]   (environment, not a URL)" >&2; exit 2 ;;
esac
# The same check the job makes, so a wrong version stops here instead of in a run.
if [ -n "$VERSION" ]; then "$(dirname "$0")/check-serving.sh" "$ENVIRONMENT" "$VERSION"; fi
TITLE="E2E $ENVIRONMENT${VERSION:+ $VERSION}"

since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run e2e.yml --repo "$REPO" --ref main -f environment="$ENVIRONMENT" -f version="$VERSION"
# The dispatch returns no run ID: the run is the one with this name created since.
run_id=
while :; do
  run_id=$(gh run list --repo "$REPO" --workflow e2e.yml --event workflow_dispatch --limit 5 \
    --json databaseId,createdAt,displayTitle \
    --jq "[.[] | select(.createdAt >= \"$since\" and .displayTitle == \"$TITLE\")] | last | .databaseId // empty")
  [ -z "$run_id" ] || break
  sleep 3
done
echo "run https://github.com/$REPO/actions/runs/$run_id"
gh run watch "$run_id" --repo "$REPO" --interval 15 --exit-status
