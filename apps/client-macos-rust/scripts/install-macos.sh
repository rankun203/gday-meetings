#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/macos-common.sh"

bash "$client_dir/scripts/build-macos.sh"
installer_dir="$target_dir/installer"
installer_assets="$client_dir/../packaging/macos"
staged_app="$installer_dir/Gday Meetings Rust.app"
legacy_staged_app="$installer_dir/Gday Meetings.app"
require_stopped_app "$staged_app"
require_stopped_app "$legacy_staged_app"
mkdir -p "$installer_dir"
/bin/cp "$installer_assets/installer-background.tiff" "$target_dir/installer-background.tiff"
# A separate copy keeps development launches working after the installer app is dragged away.
if [[ -e "$staged_app" ]]; then rm -rf "$staged_app"; fi
# This component's generated installer copy previously used the native app's name.
if [[ -e "$legacy_staged_app" ]]; then rm -rf "$legacy_staged_app"; fi
run_step "Prepare installer copy" "Check free disk space and write access to $installer_dir. Do not use sudo make." \
    /usr/bin/ditto "$app_path" "$staged_app"
if [[ ! -e "$installer_dir/Applications" && ! -L "$installer_dir/Applications" ]]; then
    ln -s /Applications "$installer_dir/Applications"
fi
run_step "Verify installer copy" "Run make install again to recreate the installer from the signed build." \
    /usr/bin/codesign --verify --strict "$staged_app"
echo "Drag Gday Meetings Rust.app onto Applications in the Finder window."
echo "Then open Gday Meetings Rust from Applications to start the client and its browser UI."
echo "Installer folder: $installer_dir"
echo "Opening an icon-view installer window (macOS may ask to allow Finder automation)."
if ! /usr/bin/osascript "$installer_assets/open-installer.applescript" "$installer_dir" "Gday Meetings Rust.app"; then
    echo "Could not set Finder's icon view. Opening the folder normally; press Command-1 in that window to show icons." >&2
    run_step "Open installer in Finder" "A logged-in macOS desktop session is required. Your built app remains available at $staged_app; open the installer folder manually." \
        /usr/bin/open "$installer_dir"
fi
