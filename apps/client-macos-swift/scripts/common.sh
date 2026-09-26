#!/bin/bash
set -euo pipefail
client_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$client_dir/.build"
app_path="$build_dir/macos/Gday Meetings.app"

check_tools() {
    if [[ "$(uname -s)" != Darwin ]]; then
        echo 'The SwiftUI client requires macOS 14.2 or later.' >&2
        exit 1
    fi
    if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
        echo 'Install Apple Command Line Tools with: xcode-select --install' >&2
        exit 1
    fi
    /usr/bin/xcrun --find swift >/dev/null
    /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null
    local swift_major swift_minor sdk_major sdk_minor sdk_patch
    read -r swift_major swift_minor <<< "$(/usr/bin/xcrun swift --version 2>&1 | /usr/bin/sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' | /usr/bin/head -1)"
    if [[ -z "$swift_major" ]] || (( swift_major < 5 || (swift_major == 5 && swift_minor < 9) )); then
        echo 'Update Apple Command Line Tools (or Xcode) to a version containing Swift 5.9 or later.' >&2
        exit 1
    fi
    IFS=. read -r sdk_major sdk_minor sdk_patch <<< "$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
    if (( sdk_major < 14 || (sdk_major == 14 && ${sdk_minor:-0} < 2) )); then
        echo 'Update Apple Command Line Tools (or Xcode) to a version containing macOS SDK 14.2 or later.' >&2
        exit 1
    fi
    local os_major os_minor
    os_major="$(/usr/bin/sw_vers -productVersion | cut -d. -f1)"
    os_minor="$(/usr/bin/sw_vers -productVersion | cut -d. -f2)"
    if (( os_major < 14 || (os_major == 14 && os_minor < 2) )); then
        echo 'Gday Meetings requires macOS 14.2 or later.' >&2
        exit 1
    fi
}

swift_package() {
    /bin/bash "$client_dir/scripts/build-audio-dependencies.sh"
    # Keep build caches local to the checkout, including on managed Macs.
    mkdir -p "$build_dir/cache" "$build_dir/clang-cache"
    CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache" \
        /usr/bin/xcrun swift "$@" --package-path "$client_dir" --cache-path "$build_dir/cache"
}

require_stopped_app() {
    # Never replace a running bundle: it may still be finalizing a recording.
    if /bin/ps -axo command= | /usr/bin/grep -F -- "$1/Contents/MacOS/GdayMeetings" | /usr/bin/grep -v grep >/dev/null; then
        echo "Quit $1 before rebuilding or replacing it." >&2
        exit 1
    fi
}
