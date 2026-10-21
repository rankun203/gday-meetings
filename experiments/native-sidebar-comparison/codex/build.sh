#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_root="${NATIVE_SIDEBAR_OUTPUT_ROOT:-/private/tmp/gday-native-sidebar-comparison}"
app_path="$output_root/Astra Native Sidebar.app"
binary="$app_path/Contents/MacOS/AstraNativeSidebar"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
architecture="$(uname -m)"

if [[ -e "$binary" ]]; then
    running_commands="$(/bin/ps -axo command=)"
    if /usr/bin/grep -Fq -- "$binary" <<< "$running_commands"; then
        printf 'Quit Astra Native Sidebar before rebuilding it.\n' >&2
        exit 1
    fi
fi

mkdir -p "$app_path/Contents/MacOS" "$output_root/astra-module-cache"
/usr/bin/xcrun swiftc \
    -O -parse-as-library \
    -target "$architecture-apple-macos26.0" \
    -sdk "$sdk_path" \
    -module-cache-path "$output_root/astra-module-cache" \
    -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$sdk_version" \
    "$source_dir/NativeSidebarApp.swift" -o "$binary"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AstraNativeSidebar</string>
    <key>CFBundleIdentifier</key><string>com.gdaymeetings.native-sidebar-codex</string>
    <key>CFBundleName</key><string>Astra Native Sidebar</string>
    <key>CFBundleDisplayName</key><string>Astra Native Sidebar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
/usr/bin/xcrun vtool -show-build "$binary"
printf 'Built %s\n' "$app_path"
