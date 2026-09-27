#!/bin/bash
# Shared paths for the component's macOS build, launch and installer scripts.
if [[ "$(uname -s)" != Darwin ]]; then
    echo "The native client currently requires macOS." >&2
    exit 1
fi

client_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
target_dir="$client_dir/target"
bundle_dir="${GDAY_MEETINGS_BUNDLE_DIR:-$target_dir/macos}"
app_path="$bundle_dir/Gday Meetings Rust.app"
executable="$app_path/Contents/MacOS/gday-meetings-client"
log_dir="${GDAY_MEETINGS_LOG_DIR:-$HOME/Library/Logs/Gday Meetings}"

report_script_failure() {
    local status="$1" script="$2" line="$3"
    printf '\n[Gday Meetings] %s failed at line %s (exit %s).\nRead the tool output above; run make doctor to check prerequisites. Check free disk space and directory permissions for packaging errors.\n' "$script" "$line" "$status" >&2
    return "$status"
}
set -E
trap 'report_script_failure "$?" "${BASH_SOURCE[0]}" "$LINENO"' ERR

require_stopped_app() {
    local candidate="$1/Contents/MacOS/gday-meetings-client"
    if [[ -f "$candidate" ]] && /usr/sbin/lsof -t "$candidate" >/dev/null 2>&1; then
        echo "Gday Meetings is running from $1. Stop recordings and quit it before rebuilding." >&2
        exit 1
    fi
}

# Describe the failed stage without hiding the original tool output or status.
run_step() {
    local description="$1" hint="$2" status
    shift 2
    printf '\n[Gday Meetings] %s\n' "$description"
    if "$@"; then return 0; else status=$?; fi
    printf '\n[Gday Meetings] FAILED: %s (exit %s)\n%s\n' "$description" "$status" "$hint" >&2
    return "$status"
}

check_build_environment() {
    local failed=0 tool version major minor sdk
    version="$(/usr/bin/sw_vers -productVersion)"
    IFS=. read -r major minor _ <<< "$version"
    if (( major < 14 || (major == 14 && minor < 2) )); then
        echo "ERROR: macOS 14.2 or newer is required; found $version. Upgrade macOS before building." >&2
        failed=1
    fi
    for tool in git make clang; do
        if ! "$tool" --version >/dev/null 2>&1; then
            echo "ERROR: $tool is unavailable. Run xcode-select --install, complete the installer, then retry." >&2
            failed=1
        fi
    done
    if ! sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-version 2>/dev/null)"; then
        echo "ERROR: No usable macOS SDK. Run xcode-select --install; check xcode-select -p if Xcode is already installed." >&2
        failed=1
    else
        IFS=. read -r major minor _ <<< "$sdk"
        if (( major < 14 || (major == 14 && minor < 2) )); then
            echo "ERROR: macOS SDK 14.2 or newer is required; found $sdk. Update your Xcode Command Line Tools." >&2
            failed=1
        fi
    fi
    for tool in cargo rustc; do
        if ! "$tool" --version >/dev/null 2>&1; then
            echo "ERROR: $tool is unavailable. Install stable Rust from https://rustup.rs, then reopen Terminal (or source \"\$HOME/.cargo/env\")." >&2
            failed=1
        fi
    done
    if ! cmake --version >/dev/null 2>&1; then
        echo "ERROR: CMake is required to build bundled Opus. Install CMake (brew install cmake if using Homebrew), then retry." >&2
        failed=1
    fi
    for tool in /usr/bin/codesign /usr/bin/plutil /usr/bin/ditto /usr/bin/open /usr/sbin/lsof; do
        if [[ ! -x "$tool" ]]; then
            echo "ERROR: Required macOS tool $tool is missing. Repair your macOS/developer tools installation." >&2
            failed=1
        fi
    done
    if (( failed )); then
        echo "Fix the errors above, then run make doctor again. No app was built or installed." >&2
        return 1
    fi
    printf 'Environment OK: macOS %s; SDK %s; %s; %s\n' "$version" "$sdk" "$(rustc --version)" "$(cmake --version | head -n 1)"
    echo "Signing uses a local ad-hoc signature; no Apple Developer account or signing certificate is required."
}
