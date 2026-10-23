#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
fixture_root="${1:?Pass the retained large fixture directory}"
mkdir -p .build/ui-benchmarks
benchmark_run="$(mktemp -d "$project_root/.build/ui-benchmarks/large-scroll-XXXXXX")"
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
benchmark_status=0
TEST_RUNNER_WEGIT_PERFORMANCE_GIT="$(xcrun --find git)" TEST_RUNNER_WEGIT_PERFORMANCE_FIXTURE="$fixture_root" \
  xcodebuild -project WeGit.xcodeproj -scheme WeGitPerformance -configuration ReleasePerformance \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 1800 \
  -maximum-test-execution-time-allowance 2400 \
    -only-testing:WeGitPerformanceTests/LargeReadingPerformanceTests \
    -resultBundlePath "$benchmark_run/Scroll.xcresult" test || benchmark_status=$?
xcrun xcresulttool export metrics --path "$benchmark_run/Scroll.xcresult" --output-path "$benchmark_run/metrics"
xcrun xcresulttool get test-results metrics --path "$benchmark_run/Scroll.xcresult" --format json > "$benchmark_run/metrics.json"
cp .build-app/Build/Products/ReleasePerformance/WeGit.app/Contents/Resources/build-source.json "$benchmark_run/build-source.json"
echo "Large UI scrolling evidence: $benchmark_run"
exit "$benchmark_status"
