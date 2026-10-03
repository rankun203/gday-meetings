#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
check_tools
unset GDAY_PERFORMANCE GDAY_NOTES_CAPACITY GDAY_SUMMARY_CAPACITY
performance_toolchain="$(cd "$(dirname "$(/usr/bin/xcrun --find swift)")/.." && pwd)"
performance_plugin="$performance_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$performance_plugin" ]]; then
    swift_package test -c release -Xswiftc -load-plugin-library -Xswiftc "$performance_plugin" \
        --filter 'NotesCapacityTests|SummaryPerformanceTests'
else
    swift_package test -c release --filter 'NotesCapacityTests|SummaryPerformanceTests'
fi
printf 'Release test bundle: %s\n' "$client_dir/.build/out/Products/Release/GdayMeetingsTests.xctest"
