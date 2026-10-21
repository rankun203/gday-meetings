---
title: Claude Native Sidebar experiment
date: 2026-10-19
status: active
scope: experiment
---

# Claude Native Sidebar

Claude Native Sidebar is a small standalone SwiftUI app. It checks whether a plain three-column `NavigationSplitView` shudders when the sidebar is shown or hidden. It doesn't use any Gday Meetings code, and all of its content is synthetic.

## Requirements

- macOS 26 or later on Apple silicon.
- Xcode. The SwiftUI `@State` macro plugin ships with Xcode, not with Command Line Tools. If `DEVELOPER_DIR` isn't set, `build.sh` uses `/Applications/Xcode.app`.

## Build

```sh
./build.sh
```

This builds `/private/tmp/gday-native-sidebar-comparison/Claude Native Sidebar.app`. To build somewhere else, pass a path that ends in `.app`:

```sh
./build.sh "/private/tmp/example/Claude Native Sidebar.app"
```

The script deletes and rebuilds the bundle at that path. It then compiles `Sources/NativeSidebarApp.swift` with `swiftc -O`, writes `Info.plist`, ad-hoc signs the bundle, and verifies the signature. The compiler module cache goes in a `module-cache` folder beside the bundle. The script writes nothing to the repository.

## Lint

```sh
xcrun swift-format lint --strict --configuration .swift-format Sources/NativeSidebarApp.swift
bash -n build.sh
```

`.swift-format` is a copy of `apps/client-macos-swift/.swift-format`.

## Test

Open the built app and follow the checks in [RESULTS.md](RESULTS.md#results). Use the toolbar sidebar button and **View > Show Sidebar** / **Hide Sidebar** (Control-Command-S).
