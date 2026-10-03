---
title: Gday Meetings artwork
date: 2026-10-03
status: active
scope: shared-branding
---

# Gday Meetings artwork

Both PNG masters in this directory are current. Preserve the approved winking koala holding ivory and orange chat bubbles; do not regenerate the character when exporting icons.

| Master | Use |
| --- | --- |
| `gday-meetings-koala.png` | Original transparent artwork for the root README and web exports. |
| `gday-meetings-koala-macos.png` | Opaque square macOS artwork, with teal extending to every edge. Avoids an inset tile inside the system's icon treatment. |

## Component exports

Exports are committed in each component so it remains independently buildable. Identical copies across components are intentional.

- [Swift macOS icon](../../apps/client-macos-swift/packaging/macos/GdayMeetings.icns).
- [Rust macOS icon](../../apps/client-macos-rust/packaging/macos/GdayMeetings.icns).
- [Rust web icon](../../apps/client-macos-rust/webui/gday-meetings.png), 256 pixels square.
- [Server and admin icon](../../apps/server/public/gday-meetings.png), 256 pixels square.

Refresh web exports from the repository root:

```sh
sips -z 256 256 docs/branding/gday-meetings-koala.png --out apps/client-macos-rust/webui/gday-meetings.png
cp apps/client-macos-rust/webui/gday-meetings.png apps/server/public/gday-meetings.png
```

For macOS, create a temporary `.iconset` folder. Export `icon_NxN.png` from the macOS master for N = 16, 32, 128, 256, and 512, plus `icon_NxN@2x.png` at twice each size. Package it with `iconutil -c icns <folder>.iconset -o <output>.icns`, then copy the result to both macOS paths above. The Swift build copies its component's icon into the app bundle before signing.

## Menu-bar artwork

The Swift app uses a separate monochrome koala template, drawn and cached in [GdayMeetingsApp.swift](../../apps/client-macos-swift/Sources/GdayMeetings/GdayMeetingsApp.swift). Recording adds a square cutout. Do not use the opaque app-icon tile as a menu-bar template. See the [menu-bar icon worklog](../worklogs/2026-10-02-koala-menu-icon.md) for the approved geometry and validation.

## Cleanup review

The October 3 review found no obsolete files in this directory. Both masters have distinct uses; the web exports match each other, and the two macOS exports match each other. Updated the legacy Rust-only export instructions and the obsolete waveform menu-bar description. No artwork was deleted or changed.
