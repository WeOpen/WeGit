#!/bin/bash
set -euo pipefail
xcodebuild -version
xcrun swift --version
test "$(uname -m)" = arm64
test "$(sw_vers -productVersion | cut -d. -f1)" -ge 27
xcodebuild -version | head -n 1 | grep -E '^Xcode 27([. ]|$)'
