#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

lake build leandb leandb_tests
.lake/build/bin/leandb_tests

for base in tickets crm shop gpus gpumarket pricewatch; do
  (
    cd "examples/$base"
    lake build
    ".lake/build/bin/${base}_tests"
  )
done

(
  cd examples/legacy
  lake build
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
