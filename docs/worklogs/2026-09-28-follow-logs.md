---
title: Follow logs from Help
date: 2026-09-28
status: complete
scope: swift-app
---

**Problem:** Help offered a log export but no action to watch new entries.

**Implemented solution:** Add Follow Logs immediately above Export Logs in the native Help menu. Open Console by bundle identifier through NSWorkspace. Report launch failures through the existing app error presentation. Document selecting the Mac, starting streaming, filtering by subsystem, and including info messages.

**Reasoning:** Use the user's preferred centralized macOS log viewer. Console owns filtering and streaming; no documented filtered-launch interface was found. The action only opens Console and does not change its current state. No command file, shell process, or terminal integration is created.

**Technical debt:** Retained toolchain issue: Swift 6.4 emits linker warnings for missing `CommandLineTools/Developer/Library/Frameworks` and `CommandLineTools/Developer/usr/lib`. The installed frameworks are under `CommandLineTools/Library/Developer/Frameworks`. The build succeeds; no flags suppress these warnings. Update or repair Command Line Tools and rerun the build to remove the stale search paths. No new application debt.

**Notes:** Before editing, inspected the production Help menu and captured the isolated Preview window. Both menus contained Export Logs only after the standard Help item. After building, accessibility inspection confirmed Follow Logs immediately above Export Logs. Captured the Preview window again; its layout remained stable. The screenshot tool cannot capture an open menu, so menu order was inspected through accessibility.

Validation: `make format-macos`, `make lint-macos`, `git diff --check`, and the signed release/Preview build passed, with the toolchain warnings above. Clicked Help → Follow Logs in rebuilt Preview and inspected Console's window and screenshot; Console displayed its existing streaming view. Menu order remained Follow Logs above Export Logs. Removed the exact cached Preview command file from the previous implementation. Launch-failure presentation and keyboard menu navigation were not exercised. The installed production app was not replaced or restarted.

Consolidated follow-up validation on October 1 passed the signed release build and all 524 Swift tests. The rebuilt isolated app exposed Follow Logs, its native menu action succeeded, and Console was running afterward. The existing toolchain linker-path warnings remain as described above.
