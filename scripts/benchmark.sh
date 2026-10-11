#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p .build/benchmarks
benchmark_run="$(mktemp -d "$project_root/.build/benchmarks/run-XXXXXX")"
swift build -c release --product WeGitBenchmarks
benchmark_binary="$(swift build -c release --show-bin-path)/WeGitBenchmarks"
python3 scripts/create-benchmark-fixtures.py --destination "$benchmark_run/fixtures"
"$benchmark_binary" "$benchmark_run/fixtures/normal" "$benchmark_run/normal.json" "$project_root" 30
"$benchmark_binary" "$benchmark_run/fixtures/large" "$benchmark_run/large.json" "$project_root" 30
echo "Reports and retained UI-performance fixtures: $benchmark_run"
