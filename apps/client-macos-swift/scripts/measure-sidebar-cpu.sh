#!/bin/bash
# Measure repeated sidebar toggles using a temporary library and unshown window.
# This opens no audio devices and submits no provider requests.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
check_tools
toolchain_usr="$(cd "$(dirname "$(/usr/bin/xcrun --find swift)")/.." && pwd)"
testing_plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
args=(test -c release -Xswiftc -enable-testing --filter SidebarPerformanceTests)
if [[ -f "$testing_plugin" ]]; then
    args+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
GDAY_PERFORMANCE=1 swift_package "${args[@]}" 2>&1 | /usr/bin/grep -E '^PERF|passed|failed|error:|warning:'
