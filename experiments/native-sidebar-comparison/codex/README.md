---
title: Astra native sidebar reference
date: 2026-10-19
status: awaiting-user-validation
scope: native-sidebar-comparison
---

# Astra native sidebar reference

This standalone macOS app provides a native three-column SwiftUI reference for the sidebar transition investigation. It contains synthetic notes and does not open the Gday Meetings library.

## Build

On a Mac with Command Line Tools that support macOS 26 or later, run:

```bash
bash experiments/native-sidebar-comparison/codex/build.sh
```

The script compiles with optimization, targets macOS 26.0, links against the selected SDK, packages the app, and verifies its ad hoc signature. The default output is `/private/tmp/gday-native-sidebar-comparison/Astra Native Sidebar.app`. Build caches also stay under that temporary directory. Set `NATIVE_SIDEBAR_OUTPUT_ROOT` to use a different output directory.

The bundle identifier is `com.gdaymeetings.native-sidebar-codex`. It is separate from the production app and the other comparison app. The script does not launch or install anything.

## Manual comparison

Open the built app when ready to test. Its default window is 1,200 by 800 points. The initial visibility preference shows the note list and detail with the sidebar hidden. Use the standard sidebar toolbar button or View menu command to reveal and hide the sidebar.

Watch the long text as the sidebar opens. Check whether it reflows during the transition, whether the toolbar toggle moves into overflow, and whether a blank strip or displaced content remains afterward. Repeat at narrower and wider sizes, then drag the column dividers and change the selected note. Record the window size and whether the problem occurs during motion or remains after it stops.

The app uses one `NavigationSplitView` directly in its scene, the balanced style, native lists, standard sidebar commands, and column-width preferences. It has no custom toolbar, nested split, geometry measurement, layout introspection, animation override, or forced layout. Results and limitations are recorded in [RESULTS.md](RESULTS.md).
