#!/usr/bin/env bash
# Builds the standalone diagnostic app with swiftc directly, outside the repository.
# Usage: ./build.sh [path/to/Claude Native Sidebar.app]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_name="Claude Native Sidebar"
bundle_id="com.gdaymeetings.native-sidebar-claude"
executable="ClaudeNativeSidebar"
app_path="${1:-/private/tmp/gday-native-sidebar-comparison/${app_name}.app}"

# The bundle is deleted and rebuilt, so refuse paths that are not app bundles.
if [[ "${app_path}" != *.app ]]; then
    echo "error: output path must end in .app: ${app_path}" >&2
    exit 1
fi

# SwiftUI macros such as @State need the plugin that ships with Xcode, not Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
# Keep the compiler module cache beside the output instead of the per-user cache.
module_cache="$(dirname "${app_path}")/module-cache"

rm -rf "${app_path}"
mkdir -p "${app_path}/Contents/MacOS"

xcrun swiftc \
    -O \
    -parse-as-library \
    -target arm64-apple-macosx26.0 \
    -sdk "${sdk_path}" \
    -module-cache-path "${module_cache}" \
    -o "${app_path}/Contents/MacOS/${executable}" \
    "${script_dir}/Sources/NativeSidebarApp.swift"

cat > "${app_path}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${app_name}</string>
    <key>CFBundleExecutable</key>
    <string>${executable}</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${app_name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "${app_path}/Contents/Info.plist"

codesign --force --sign - "${app_path}"
codesign --verify --strict --verbose=2 "${app_path}"

echo "Built ${app_path}"
