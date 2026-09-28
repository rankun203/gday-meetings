---
title: Open a meeting folder from its header
date: 2026-09-28
status: complete
scope: swift-app
---

## Problem

The meeting detail title supported editing but offered no direct way to open its storage folder.

## Implemented solution

Command-clicking the title opens the displayed meeting's folder in Finder. The title also offers **Open Meeting Folder** through its context menu and accessibility actions. Help describes both Command-click and double-click editing.

The captured Preview baseline showed a single-line title beside the compact play button. Keep that layout, truncation, and normal double-click editor. The folder action resolves the detail's meeting ID independently of the player.

## Reasoning

Use SwiftUI's [modifier-aware gesture](https://developer.apple.com/documentation/swiftui/gesture/modifiers(_:)) with precedence over double-click editing. The modifier is part of gesture recognition, so releasing Command after the click cannot change its meaning. Opening the directory with `NSWorkspace.open` shows its contents; existing Reveal in Finder actions still select an item in its parent folder.

## Validation

Release Preview build passed, and both existing title editor tests passed. `make format-macos` and focused formatting/diff checks passed. Repository-wide lint encountered in-progress formatting in the parallel summary-images task; that task will run final formatting. Before/after Preview screenshots confirmed the same single-line header layout. An ordinary click left the title unchanged; double-click opened the editor and Escape discarded a typed draft. The named folder action opened the displayed synthetic meeting's contents in Finder while the player referenced a different meeting.

Physical Command-click remains untested because the UI automation API does not expose modified mouse clicks; its native gesture declaration was reviewed. Light appearance and small-window checks were not repeated because this change adds no visual styling or layout. The installed app was not restarted or replaced.

Build and test linking retained the existing Command Line Tools warnings for missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths. No API deprecation warnings occurred. These toolchain paths require a separate toolchain repair or update; the feature needs no compatibility workaround.

## Technical debt

None introduced.
