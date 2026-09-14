#!/usr/bin/env bash
# Reproduce the B2T2 evaluation from benchmarks/b2t2/.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd ../.. && pwd)"
mkdir -p results
{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "engine_sha: $(git -C "$ROOT" rev-parse HEAD)"
  echo "engine_describe: $(git -C "$ROOT" describe --always --dirty)"
  echo "b2t2_pin: fd227efadf532a20aefd25c7a8580978c2d684a2"
  echo "lean: $(lean --version 2>/dev/null || true)"
  echo "uname: $(uname -s -m)"
  echo "---"
  lake build b2t2_tests
  echo "---"
  ./.lake/build/bin/b2t2_tests
} | tee results/run.log
