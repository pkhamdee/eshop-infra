#!/usr/bin/env bash
# Dependency-scan gate: Trivy (pinned image) over the lockfiles, i.e. the full resolved dependency graph of
# every service: npm package-lock.json (development dependencies included: they run in our builds) and NuGet
# packages.lock.json (eshop-api / eshop-sync-master; kept by RestorePackagesWithLockFile).
#
#   scripts/gates/deps.sh          # needs docker; CI runs it in the `deps` job (ci-release.yml)
#   GATES_SOURCE=../eshop-web scripts/gates/deps.sh   # a service repository's lockfiles (service-image.yml)
#
# Fails (exit 1) on any CRITICAL vulnerability, fixed or not, as the image scan does. Other severities are
# reported but never fail. Reports go to $REPORT_DIR (default: reports/deps): trivy.json (every severity),
# trivy.txt (readable table). Trivy's database is cached in $GATES_CACHE (default ~/.cache/eshop-gates).
set -euo pipefail

TRIVY_IMAGE=aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c
# Not ours (third-party agent skills, other worktrees) or not lockfiles (installed and built output).
SKIP_DIRS=(.git .agents .claude "**/node_modules" "**/bin" "**/obj")

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
report_dir=$(gate_report_dir deps)
cache=$(gate_cache trivy)
repo=$GATES_SOURCE

skips=()
for dir in "${SKIP_DIRS[@]}"; do skips+=(--skip-dirs "$dir"); done

trivy() {
  docker run --rm --user "$(id -u):$(id -g)" \
    -v "$repo:/src:ro" -v "$cache:/cache" -v "$report_dir:/reports" -w /src \
    "$TRIVY_IMAGE" --cache-dir /cache --quiet "$@"
}

trivy fs --scanners vuln --include-dev-deps "${skips[@]}" --format json --output /reports/trivy.json .
trivy convert --format table --output /reports/trivy.txt /reports/trivy.json
if [ -s "$report_dir/trivy.txt" ]; then cat "$report_dir/trivy.txt"; else echo "No known vulnerabilities in any lockfile."; fi

if ! trivy convert --format table --severity CRITICAL --exit-code 1 --output /reports/critical.txt /reports/trivy.json; then
  cat "$report_dir/critical.txt"
  echo "deps gate: FAILED: critical vulnerabilities above (full report: $report_dir)" >&2
  exit 1
fi
echo "deps gate: passed: no critical vulnerabilities (full report: $report_dir)"
