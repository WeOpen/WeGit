#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
fixture_root="${1:?Pass the retained normal fixture directory}"
sample_count="${2:-30}"
case "$sample_count" in 1|30) ;; *) echo "Samples must be 1 (smoke) or 30 (acceptance)." >&2; exit 2 ;; esac
mkdir -p .build/ui-benchmarks
benchmark_run="$(mktemp -d "$project_root/.build/ui-benchmarks/workbench-XXXXXX")"
if [[ "${WEGIT_SKIP_PROJECT_GENERATION:-0}" != 1 ]] && command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
benchmark_status=0
TEST_RUNNER_WEGIT_PERFORMANCE_GIT="$(xcrun --find git)" TEST_RUNNER_WEGIT_PERFORMANCE_FIXTURE="$fixture_root" TEST_RUNNER_WEGIT_PERFORMANCE_RESULTS="$benchmark_run" TEST_RUNNER_WEGIT_PERFORMANCE_SAMPLES="$sample_count" \
  xcodebuild -project WeGit.xcodeproj -scheme WeGitPerformance -configuration ReleasePerformance \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-app \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 1800 \
  -maximum-test-execution-time-allowance 2400 \
    -only-testing:WeGitPerformanceTests/WorkbenchPerformanceTests \
    -resultBundlePath "$benchmark_run/Workbench.xcresult" test || benchmark_status=$?
xcrun xcresulttool get test-results summary --path "$benchmark_run/Workbench.xcresult" > "$benchmark_run/summary.json"
xcrun xcresulttool export attachments --path "$benchmark_run/Workbench.xcresult" --output-path "$benchmark_run/attachments"
python3 scripts/summarize_workbench_benchmark.py --run "$benchmark_run" --fixture "$fixture_root" \
  --receipt .build-app/Build/Products/ReleasePerformance/WeGit.app/Contents/Resources/build-source.json
echo "Actual UI measurements: $benchmark_run"
exit "$benchmark_status"
