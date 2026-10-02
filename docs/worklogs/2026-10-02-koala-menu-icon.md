---
title: Koala menu-bar icon
date: 2026-10-02
status: implemented
scope: swift-app-menu-bar
---

# Problem

The circular recording icon resembles the system screen-recording stop control.

# Implemented solution

Use the approved koala silhouette with the taller headband in both menu-bar states. Recording adds a smaller square cutout in Refined D's lower position. Preview guide borders are excluded. The application icon, menu actions, and recording lifecycle stay unchanged.

# Reasoning

The ears distinguish the app, while the taller headband balances the silhouette inside a square canvas. A native vector template lets macOS supply the correct menu-bar tint. Cache both states instead of drawing new images on recording timer updates.

# Technical debt

None. The artwork uses public native drawing and template-image APIs.

# Validation

The original menu-bar screenshot and approved light/dark comparison were inspected before implementation. The approved geometry uses a 24-unit canvas, 1.1-unit headband, and 5.2-unit stop square centered at (12, 15.6). Both states are cached 20-point template images.

Rendered the actual application helper in an isolated native harness and inspected both states at native and enlarged sizes. Orientation, headband spacing, and the lower square match the approved design. Alpha checks confirm the square is transparent while the normal-state center is opaque; both images report `isTemplate = true`. Formatting, strict lint, and diff checks passed. The isolated release build passed in 148.24 seconds through `make build-macos-preview`, which runs `make build-macos`; plist and signing checks passed. The source snapshot matches the working tree.

Existing Command Line Tools linker warnings report missing Developer library/framework search paths. No deprecated API warnings were observed. No recording controls were invoked; the installed app and active recording remain untouched. Actual system menu-bar capture is not part of this validation. No push was requested, so remote CI was not run.
