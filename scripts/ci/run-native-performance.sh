#!/bin/bash
set -euo pipefail
samples="${1:?Pass 1 or 30}"
case "$samples" in 1|30) ;; *) exit 2 ;; esac
if [[ "$samples" == 30 ]]; then
  python3 scripts/ci/native_performance.py
else
  scripts/benchmark-ui-workbench.sh "$PWD/.build/benchmarks/native/fixtures/normal" 1
  scripts/benchmark-ui-workbench.sh "$PWD/.build/benchmarks/native/fixtures/large" 1
fi
