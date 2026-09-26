#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
bash "$client_dir/scripts/build-macos.sh"
installer_dir="$build_dir/installer"
installer_assets="$client_dir/../packaging/macos"
staged_app="$installer_dir/Gday Meetings.app"
legacy_staged_app="$installer_dir/Gday Meetings Swift.app"
require_stopped_app "$staged_app"
require_stopped_app "$legacy_staged_app"
mkdir -p "$installer_dir"
/bin/cp "$installer_assets/installer-background.tiff" "$build_dir/installer-background.tiff"
# The disposable staging copy can be dragged away without removing the build.
if [[ -e "$staged_app" ]]; then /bin/rm -rf "$staged_app"; fi
# Remove the former generated staging copy so Finder offers only the current app.
if [[ -e "$legacy_staged_app" ]]; then /bin/rm -rf "$legacy_staged_app"; fi
/usr/bin/ditto "$app_path" "$staged_app"
if [[ ! -e "$installer_dir/Applications" && ! -L "$installer_dir/Applications" ]]; then
    /bin/ln -s /Applications "$installer_dir/Applications"
fi
/usr/bin/codesign --verify --strict "$staged_app"
printf 'Drag Gday Meetings.app onto Applications, then open it.\nInstaller folder: %s\n' "$installer_dir"
echo 'Opening the installer in icon view. macOS may ask to allow Finder automation.'
if ! /usr/bin/osascript "$installer_assets/open-installer.applescript" "$installer_dir" "Gday Meetings.app"; then
    echo 'Could not set Finder icon view. Opening the folder normally; press Command-1 to show icons.' >&2
    /usr/bin/open "$installer_dir"
fi
