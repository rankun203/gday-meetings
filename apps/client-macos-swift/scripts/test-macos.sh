#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
check_tools
# AppKit fixtures share NSApplication, focus, and the main run loop. Isolate
# test cases by default; concurrency scenarios still create their own tasks.
test_execution=(--no-parallel)
for argument in "$@"; do
    case "$argument" in
        --parallel|--no-parallel) test_execution=(); break ;;
    esac
done
# Some standalone Command Line Tools releases omit the Swift Testing macro
# plugin from swiftbuild's module-emission step. Supply the installed plugin
# explicitly when available; Xcode/older toolchains retain normal discovery.
toolchain_usr="$(cd "$(dirname "$(/usr/bin/xcrun --find swift)")/.." && pwd)"
testing_plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$testing_plugin" ]]; then
    swift_package test -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" "${test_execution[@]}" "$@"
else
    swift_package test "${test_execution[@]}" "$@"
fi
