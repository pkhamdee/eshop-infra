#!/usr/bin/env bash
# The temporary copy of eShop (ADR 0007): the gate that starts it from a set of images, waits until every part is
# healthy and the demo data is seeded, and throws it away. CI runs it before any image is pushed; it runs the same
# way on this Mac. The copy itself is scripts/gates/temporary-copy/compose.yaml.
#
#   scripts/gates/temporary-copy.sh build   # build the four images (temporary-copy/<svc>:local) from the service
#                                           # repositories' clones beside this one (../<svc>, scripts/clone-all.sh)
#   scripts/gates/temporary-copy.sh up      # start the copy and wait until it is ready: exit 0, or exit 1 and remove it
#   scripts/gates/temporary-copy.sh down    # stop it and throw its data away
#
# Images (default: the :local ones `build` makes): ESHOP_WEB_IMAGE, ESHOP_API_IMAGE, ESHOP_NODE_API_IMAGE,
#   THIRDPARTY_MOCK_IMAGE, e.g. ESHOP_API_IMAGE=docker.io/pkhamdee/eshop-api:main-93392bd.
# TEMPORARY_COPY_PORT             host port of the copy's gateway, on 127.0.0.1 (default 8090)
# TEMPORARY_COPY_TIMEOUT_SECONDS  how long `up` waits for every part to become healthy (default 180)
# TEMPORARY_COPY_REPORT_DIR       where `up` writes the copy's status and logs when it fails (default reports/temporary-copy)
# TEMPORARY_COPY_KEEP=1           `up` leaves a copy that failed running, to look into it (then run `down`)
# TEMPORARY_COPY_STAFF_USERNAME / _PASSWORD   the throwaway Staff account, and TEMPORARY_COPY_NODE_IMAGE the
#                                 readiness check's Node image (defaults: temporary-copy/defaults.env)
#
# Ready means: eshop-api, eshop-node-api, thirdparty-mock, eshop-web and the gateway answer their probes
# (PostgreSQL through eshop-api's readiness), and through the gateway the demo catalog and its photos are there, a
# Customer signs in by SMS code from the mock's inbox and the Staff account signs in (temporary-copy/ready.mjs).
# On this Mac, point Docker at Rancher Desktop first: DOCKER_HOST=unix://$HOME/.rd/docker.sock.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
gate_copy_defaults # the Staff account and the Node image (temporary-copy/defaults.env); compose.yaml reads them
root=$GATES_ROOT
compose_file="$root/scripts/gates/temporary-copy/compose.yaml"
timeout=${TEMPORARY_COPY_TIMEOUT_SECONDS:-180}

compose() {
  docker compose -f "$compose_file" "$@"
}

build() {
  # Same contexts and Dockerfiles as the service repositories' CI; the copy has no sync master.
  docker build -t temporary-copy/eshop-web:local "$(gate_service_dir eshop-web)"
  api=$(gate_service_dir eshop-api)
  docker build -t temporary-copy/eshop-api:local -f "$api/src/Eshop.Api/Dockerfile" "$api"
  docker build -t temporary-copy/eshop-node-api:local "$(gate_service_dir eshop-node-api)"
  docker build -t temporary-copy/thirdparty-mock:local "$(gate_service_dir thirdparty-mock)"
}

report_failure() {
  local report_dir
  report_dir=$(gate_report_dir temporary-copy "${TEMPORARY_COPY_REPORT_DIR:-}")
  compose ps -a >"$report_dir/ps.txt" 2>&1 || true
  compose logs --no-color --timestamps >"$report_dir/logs.txt" 2>&1 || true
  echo "::error::The temporary copy did not become ready; status and logs in $report_dir"
  cat "$report_dir/ps.txt"
  echo "--- last log lines of each part ---"
  for service in eshop-api eshop-node-api thirdparty-mock eshop-web gateway postgres; do
    echo "[$service]"
    compose logs --no-color --tail 15 "$service" 2>&1 || true
  done
  if [ "${TEMPORARY_COPY_KEEP:-}" = 1 ]; then
    echo "Left running (TEMPORARY_COPY_KEEP=1); remove it with: $0 down"
  else
    down
  fi
  exit 1
}

up() {
  echo "Temporary copy images:"
  compose config --images | sed 's/^/  /'
  # --wait: until every part with a healthcheck is healthy (and none has exited); eshop-api has no tools for one
  # in its chiseled image, so ready.mjs checks it.
  compose up --quiet-pull --detach --wait --wait-timeout "$timeout" || report_failure
  compose --profile check run --rm ready || report_failure
  echo "Temporary copy ready at http://localhost:${TEMPORARY_COPY_PORT:-8090} (Staff: ${TEMPORARY_COPY_STAFF_USERNAME:-staff})"
}

down() {
  compose --profile check down --volumes --remove-orphans --timeout 5
}

case "${1:-}" in
  build) build ;;
  up) up ;;
  down) down ;;
  *)
    echo "usage: $0 build | up | down" >&2
    exit 2
    ;;
esac
