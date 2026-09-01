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
    schema_json=$(".lake/build/bin/$base" schema)
    if [[ "$schema_json" != *'"ok":true'* ]]; then
      echo "release check failed: $base schema smoke test failed" >&2
      exit 1
    fi
  )
done

(
  cd examples/legacy
  lake build
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
