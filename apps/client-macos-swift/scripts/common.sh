#!/bin/bash
set -euo pipefail
client_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$client_dir/.build"
app_path="$build_dir/macos/Gday Meetings.app"

check_tools() {
    if [[ "$(uname -s)" != Darwin ]]; then
        echo 'The SwiftUI client requires macOS 26 or later.' >&2
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
    if [[ -z "$swift_major" ]] || (( swift_major < 6 || (swift_major == 6 && swift_minor < 2) )); then
        echo 'Building Gday Meetings requires Swift 6.2 or later. Update Apple Command Line Tools or Xcode to version 26 or later and select the updated developer tools.' >&2
        exit 1
    fi
    IFS=. read -r sdk_major sdk_minor sdk_patch <<< "$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
    if (( sdk_major < 26 )); then
        echo 'Building Gday Meetings requires macOS SDK 26 or later. Update Apple Command Line Tools or Xcode to version 26 or later and select the updated developer tools.' >&2
        exit 1
    fi
    local os_major
    os_major="$(/usr/bin/sw_vers -productVersion | cut -d. -f1)"
    if (( os_major < 26 )); then
        echo 'Gday Meetings requires macOS 26 or later.' >&2
        exit 1
    fi
}

swift_package() {
    /bin/bash "$client_dir/scripts/build-audio-dependencies.sh"
    /bin/bash "$client_dir/scripts/build-search-dependencies.sh"
    # Swift Build can stamp the deployment target as the SDK version, which
    # selects older AppKit/SwiftUI compatibility behavior. Pass both versions
    # explicitly to the linker; this does not raise the deployment target.
    local app_minimum sdk_version
    app_minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$client_dir/packaging/macos/Info.plist")"
    sdk_version="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
    # Keep build caches local to the checkout, including on managed Macs.
    mkdir -p "$build_dir/cache" "$build_dir/clang-cache"
    CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache" \
        /usr/bin/xcrun swift "$@" --package-path "$client_dir" --cache-path "$build_dir/cache" \
        -Xlinker -platform_version -Xlinker macos -Xlinker "$app_minimum" -Xlinker "$sdk_version"
}

require_stopped_app() {
    # Never replace a running bundle: it may still be finalizing a recording.
    if /bin/ps -axo command= | /usr/bin/grep -F -- "$1/Contents/MacOS/GdayMeetings" | /usr/bin/grep -v grep >/dev/null; then
        echo "Quit $1 before rebuilding or replacing it." >&2
        exit 1
    fi
}
