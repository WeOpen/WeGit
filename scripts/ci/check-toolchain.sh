#!/bin/bash
set -euo pipefail
# Drain the complete output: piping xcodebuild into head can make its second
# write raise NSFileHandleOperationException / SIGPIPE on a hosted runner.
xcode_version="$(xcodebuild -version)"
printf '%s\n' "$xcode_version"
xcrun swift --version
test "$(uname -m)" = arm64
test "$(sw_vers -productVersion | cut -d. -f1)" -ge 27
case "$xcode_version" in
  "Xcode 27."*|"Xcode 27"$'\n'*) ;;
  *) echo 'Xcode 27 is required.' >&2; exit 1 ;;
esac
