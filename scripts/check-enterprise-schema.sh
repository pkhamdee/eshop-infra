#!/usr/bin/env bash
# Keeps the mock Enterprise schema the cluster gets identical to the one eshop-sync-master is tested against (#105).
# The source of truth is pkhamdee/eshop-api's tests/Eshop.SyncMaster.Tests/enterprise-schema.sql: its tests apply it.
# This repository deploys a copy, deploy/thirdparty/mssql/enterprise-schema.sql (a kustomize configMapGenerator needs
# a local file). CI's `repo rules` job runs this; a schema change lands in eshop-api first, then here.
#
#   scripts/check-enterprise-schema.sh
#
# ENTERPRISE_SCHEMA_SOURCE: where eshop-api's copy is read from, a URL (default: its main on GitHub) or a local file
# (e.g. ../eshop-api/tests/Eshop.SyncMaster.Tests/enterprise-schema.sql). Exit 0 when identical, 1 with the
# difference, or when the source can't be read. scripts/tests/release-scripts.sh tests it with local files.
set -euo pipefail

cd "$(dirname "$0")/.."
deployed=deploy/thirdparty/mssql/enterprise-schema.sql
source=${ENTERPRISE_SCHEMA_SOURCE:-https://raw.githubusercontent.com/pkhamdee/eshop-api/main/tests/Eshop.SyncMaster.Tests/enterprise-schema.sql}

tested=$(mktemp)
trap 'rm -f "$tested"' EXIT
if [[ "$source" == http*://* ]]; then
  curl -fsSL "$source" -o "$tested" || { echo "can't read eshop-api's Enterprise schema from $source" >&2; exit 1; }
else
  cp "$source" "$tested" 2>/dev/null || { echo "can't read eshop-api's Enterprise schema from $source" >&2; exit 1; }
fi

if ! diff -u --label "eshop-api: tests/Eshop.SyncMaster.Tests/enterprise-schema.sql" --label "$deployed" \
  "$tested" "$deployed"; then
  echo "$deployed differs from the schema eshop-sync-master is tested against ($source): copy that one here" >&2
  exit 1
fi
echo "$deployed is the schema eshop-sync-master is tested against."
