#!/bin/bash
# Prints CPU measurements for recording work: an unshown recording window with
# 10 Hz meters, capture processing on synthetic audio, and drain-timer wakeups.
# Results depend on the Mac and its load; run on a quiet machine and compare
# runs from the same session. No device is opened and no window is shown.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
check_tools
toolchain_usr="$(cd "$(dirname "$(/usr/bin/xcrun --find swift)")/.." && pwd)"
testing_plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
args=(test -c release -Xswiftc -enable-testing --filter RecordingPerformanceTests)
if [[ -f "$testing_plugin" ]]; then
    args+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
GDAY_PERFORMANCE=1 swift_package "${args[@]}" 2>&1 | /usr/bin/grep -E '^PERF|passed|failed|error:|warning:'
