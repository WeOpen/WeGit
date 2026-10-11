#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p .build/ui-benchmarks
benchmark_run="$(mktemp -d "$project_root/.build/ui-benchmarks/launch-XXXXXX")"
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
xcodebuild -project WeGit.xcodeproj -scheme WeGitPerformance -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app \
  -only-testing:WeGitPerformanceTests/LaunchPerformanceTests \
  -resultBundlePath "$benchmark_run/Launch.xcresult" test
xcrun xcresulttool get test-results metrics --path "$benchmark_run/Launch.xcresult" > "$benchmark_run/metrics.json"
python3 scripts/summarize_launch_benchmark.py --run "$benchmark_run" --app "$project_root/.build-app/Build/Products/Release/WeGit.app"
echo "Launch measurements: $benchmark_run"
