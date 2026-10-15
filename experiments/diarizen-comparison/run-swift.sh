#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$experiment_dir/../.." && pwd)"
mode="${1:-}"
if [[ "$mode" != community && "$mode" != project ]] || [[ $# -lt 4 ]]; then
    echo 'Usage: run-swift.sh community INPUTS OUTPUT MODEL_ROOT [Swift test options]'
    echo '       run-swift.sh project INPUTS OUTPUT TRANSCRIPT RESULTS [Swift test options]'
    exit 2
fi
export GDAY_DIARIZATION_BENCHMARK="$mode"
export GDAY_DIARIZATION_BENCHMARK_INPUTS="$2"
export GDAY_DIARIZATION_BENCHMARK_OUTPUT="$3"
if [[ "$mode" == community ]]; then
    export GDAY_DIARIZATION_BENCHMARK_MODEL_ROOT="$4"
    shift 4
else
    [[ $# -ge 5 ]] || { echo 'Project mode requires a results manifest.'; exit 2; }
    export GDAY_DIARIZATION_BENCHMARK_TRANSCRIPT="$4"
    export GDAY_DIARIZATION_BENCHMARK_RESULTS="$5"
    shift 5
fi
cd "$repo_dir"
if [[ "${1:-}" == --direct ]]; then
    shift
    toolchain_usr="$(cd "$(dirname "$(/usr/bin/xcrun --find swift)")/.." && pwd)"
    developer_dir="$(/usr/bin/xcode-select -p)"
    testing_frameworks="$developer_dir/Library/Developer/Frameworks"
    testing_libraries="$developer_dir/Library/Developer/usr/lib"
    runner="$toolchain_usr/libexec/swift/pm/swiftpm-testing-helper"
    test_binary="$repo_dir/apps/client-macos-swift/.build/out/Products/Release/GdayMeetingsTests.xctest/Contents/MacOS/GdayMeetingsTests"
    if [[ ! -x "$runner" || ! -f "$test_binary" || ! -d "$testing_frameworks/Testing.framework" ]]; then
        echo 'Direct execution requires a built release test bundle and the verified Command Line Tools runtime layout.'
        exit 2
    fi
    export DYLD_FRAMEWORK_PATH="$testing_frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
    export DYLD_LIBRARY_PATH="$testing_libraries${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    exec "$runner" --test-bundle-path "$test_binary" --testing-library swift-testing \
        --filter DiarizationComparisonHarnessTests "$@"
fi
exec bash apps/client-macos-swift/scripts/test-macos.sh -c release \
    --filter DiarizationComparisonHarnessTests "$@"
