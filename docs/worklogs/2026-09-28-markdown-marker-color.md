---
title: Markdown list marker colors
date: 2026-09-28
status: complete
scope: swift-app-ui
---

## Problem

Summary list bullets appeared black against the dark document background. The isolated Preview screenshot reproduced the problem with synthetic text: body text adapted to Dark Mode, but the separately inserted marker had no foreground color.

## Implemented solution

The native Markdown renderer applies `NSColor.labelColor` to list markers, matching the body text. Unordered and numbered lists share the fix. Marker size, indentation, document text, selection, and source-copy behavior remain unchanged. Notes reading mode uses the same renderer.

## Reasoning

Use the existing semantic text color rather than a fixed light or dark color, so AppKit resolves the color for the current appearance and accessibility settings.

## Validation

Captured and inspected the dark Preview baseline before editing. After rebuilding, Preview screenshots confirmed light bullets matching the body in Dark Mode and dark bullets matching the body in Light appearance, with unchanged layout. The Summary source-image link also opened the correct original in a Light appearance Quick Look popup.

The release Preview build passed. All 11 `MarkdownReadingTests` passed, including the new unordered/numbered marker color regression under Aqua and Dark Aqua and existing source-copy, selection, preview-line, and task-geometry regressions. `make format-macos`, `make lint-macos`, and `git diff --check` passed. Build/test linking retained existing missing Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` search-path warnings; no API deprecation warning was introduced. Toolchain repair remains separate maintenance work.

The installed app was not restarted or replaced. High Contrast and narrow-window checks were not repeated for this color-only change; the renderer uses the same semantic color as its existing body text.

## Technical debt

None.
