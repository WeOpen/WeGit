#!/bin/bash
set -euo pipefail
samples="${1:?Pass 1 or 30}"
scope="${2:-full}"
case "$samples" in 1|30) ;; *) exit 2 ;; esac
case "$scope" in full|launch|scroll) ;; *) exit 2 ;; esac
if [[ "$samples" != 30 && "$scope" != full ]]; then exit 2; fi
if [[ "$samples" == 30 ]]; then
  python3 scripts/ci/native_performance.py --scope "$scope"
else
  scripts/benchmark-ui-workbench.sh "$PWD/.build/benchmarks/native/fixtures/normal" 1
  scripts/benchmark-ui-workbench.sh "$PWD/.build/benchmarks/native/fixtures/large" 1
fi
