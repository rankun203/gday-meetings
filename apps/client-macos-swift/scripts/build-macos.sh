#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
check_tools
require_stopped_app "$app_path"
swift_package build -c release
binary_dir="$(swift_package build -c release --show-bin-path)"
linked_versions="$(/usr/bin/xcrun vtool -show-build "$binary_dir/GdayMeetings")"
linked_sdk="$(printf '%s\n' "$linked_versions" | /usr/bin/awk '$1 == "sdk" { print $2; exit }')"
linked_minimum="$(printf '%s\n' "$linked_versions" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
expected_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
expected_minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$client_dir/packaging/macos/Info.plist")"
if [[ "$linked_sdk" != "$expected_sdk" || "$linked_minimum" != "$expected_minimum" ]]; then
    printf 'Unexpected linked platform: minimum %s, SDK %s; expected minimum %s, SDK %s.\n' \
        "$linked_minimum" "$linked_sdk" "$expected_minimum" "$expected_sdk" >&2
    exit 1
fi
printf 'Linked platform: macOS %s minimum, SDK %s.\n' "$linked_minimum" "$linked_sdk"
require_stopped_app "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
/bin/cp "$binary_dir/GdayMeetings" "$app_path/Contents/MacOS/GdayMeetings"
/usr/bin/ditto "$binary_dir/GdayMeetings_GdayMeetings.bundle" "$app_path/Contents/Resources/GdayMeetings_GdayMeetings.bundle"
/usr/bin/ditto "$binary_dir/swift-transformers_Hub.bundle" "$app_path/Contents/Resources/swift-transformers_Hub.bundle"
/usr/bin/ditto "$binary_dir/swift-crypto_Crypto.bundle" "$app_path/Contents/Resources/swift-crypto_Crypto.bundle"
/usr/bin/ditto "$binary_dir/FluidAudio_FluidAudio.bundle" "$app_path/Contents/Resources/FluidAudio_FluidAudio.bundle"
/bin/cp "$client_dir/packaging/macos/Info.plist" "$app_path/Contents/Info.plist"
/bin/cp "$client_dir/packaging/macos/GdayMeetings.icns" "$app_path/Contents/Resources/GdayMeetings.icns"
/usr/bin/ditto "$build_dir/native-audio-$(uname -m)/install/licenses" "$app_path/Contents/Resources/ThirdPartyLicenses"
# Remove the retired attribution from reused build bundles.
/bin/rm -rf "$app_path/Contents/Resources/ThirdPartyLicenses/CLSP"
/usr/bin/ditto "$client_dir/ThirdParty/swift-tokenizer-licenses" "$app_path/Contents/Resources/ThirdPartyLicenses/SwiftTokenizers"
/usr/bin/ditto "$client_dir/ThirdParty/search-licenses" "$app_path/Contents/Resources/ThirdPartyLicenses/Search"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
/usr/bin/codesign --force --sign "${GDAY_CODESIGN_IDENTITY:--}" "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
printf 'Built %s\n' "$app_path"
