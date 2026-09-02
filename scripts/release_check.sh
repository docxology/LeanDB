#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

for base in tickets crm shop gpus gpumarket pricewatch eats kernels legacy; do
  if ! cmp -s lean-toolchain "examples/$base/lean-toolchain"; then
    echo "release check failed: examples/$base/lean-toolchain differs from root" >&2
    exit 1
  fi
done

lake build leandb leandb_tests
.lake/build/bin/leandb_tests

for base in tickets crm shop gpus gpumarket pricewatch eats kernels; do
  (
    cd "examples/$base"
    lake build "$base" "${base}_tests"
    ".lake/build/bin/${base}_tests"
    if [[ "$base" == "eats" ]]; then
      lake build eats_offers_tests
      .lake/build/bin/eats_offers_tests
    fi
    schema_json=$(".lake/build/bin/$base" schema)
    if [[ "$schema_json" != *'"ok":true'* ]]; then
      echo "release check failed: $base schema smoke test failed" >&2
      exit 1
    fi
  )
done

# HTTP smoke: tickets over serve --http answers the typed routes and /rpc
(
  cd examples/tickets
  http_db=$(mktemp /tmp/leandb-http.XXXXXX)
  rm -f "$http_db"
  .lake/build/bin/tickets --db "$http_db" serve --http 7433 >/dev/null 2>&1 &
  http_pid=$!
  sleep 2
  ok=1
  curl -sf -X POST http://127.0.0.1:7433/seed | grep -q '"seeded":true' || ok=0
  curl -sf http://127.0.0.1:7433/query/slaBreached/1700000000 | grep -q '"ok":true' || ok=0
  curl -sf -X POST http://127.0.0.1:7433/rpc -d '["rows","ticket","--limit","1"]' | grep -q '"count":1' || ok=0
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-LeanDb-Fingerprint: stale' http://127.0.0.1:7433/version)
  [[ "$code" == "409" ]] || ok=0
  kill "$http_pid" 2>/dev/null || true
  wait "$http_pid" 2>/dev/null || true
  rm -f "$http_db"
  if [[ "$ok" != 1 ]]; then
    echo "release check failed: tickets serve --http smoke test failed" >&2
    exit 1
  fi
)

(
  cd examples/legacy
  lake build
  .lake/build/bin/legacy_tests
  schema_json=$(.lake/build/bin/legacy schema)
  if [[ "$schema_json" != *'"ok":true'* ]]; then
    echo "release check failed: legacy schema smoke test failed" >&2
    exit 1
  fi
)

import_dir=$(mktemp -d /tmp/leandb-release-check.XXXXXX)
trap 'rm -rf "$import_dir"' EXIT

.lake/build/bin/leandb import-sqlite examples/import-fixture/legacy.db \
  --name release_fixture \
  --out "$import_dir" \
  --require-path "$repo_root" \
  --db-path data/legacy.db

test -f "$import_dir/ReleaseFixture/Entities.lean"
test -f "$import_dir/import-report.json"
cmp -s lean-toolchain "$import_dir/lean-toolchain"

(
  cd "$import_dir"
  lake build
  schema_json=$(.lake/build/bin/release_fixture schema)
  if [[ "$schema_json" != *'"ok":true'* ]]; then
    echo "release check failed: generated package schema smoke test failed" >&2
    exit 1
  fi
)

if .lake/build/bin/leandb import-sqlite examples/import-fixture/legacy.db \
    --name release_fixture \
    --out "$import_dir" \
    --require-path "$repo_root" \
    --db-path data/legacy.db >/dev/null 2>&1; then
  echo "release check failed: importer overwrote an existing generated package" >&2
  exit 1
fi

git diff --check
echo "LeanDB release checks passed"
