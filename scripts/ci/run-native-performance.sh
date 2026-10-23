#!/bin/bash
set -euo pipefail
samples="${1:?Pass 1 or 30}"
case "$samples" in 1|30) ;; *) exit 2 ;; esac
scripts/benchmark-ui-workbench.sh "$PWD/.build/benchmarks/native/fixtures/normal" "$samples"
scripts/benchmark-ui-workbench.sh "$PWD/.build/benchmarks/native/fixtures/large" "$samples"
if [[ "$samples" == 30 ]]; then
  scripts/benchmark-ui-launch.sh
  scripts/benchmark-ui-large-scroll.sh "$PWD/.build/benchmarks/native/fixtures/large"
fi
