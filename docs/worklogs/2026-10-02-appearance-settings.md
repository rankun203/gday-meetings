---
title: General appearance preference
date: 2026-10-02
status: complete
scope: macos-settings
---

## Problem

General had no appearance preference. Only UI Preview exposed System, Light, and Dark, and its choice did not persist.

## Implemented solution

General has an Appearance dropdown in a General section in the left column, below After Recording. System is the default; Light and Dark override the app’s appearance immediately. The choice persists in this Mac’s app preferences and applies when the app opens. Preview’s banner uses the same preference, within its separate app identity.

`AppearanceSettings` owns the selection and applies it through `NSApplication.appearance`. The app supplies one instance to General and Preview. The preference is independent of meeting libraries and recording state.

## Reasoning

Before editing, captured and inspected General in the isolated preview. Its recording controls started at the top left, with capability providers on the right. The design adds a General section below After Recording in the left column, with a native Appearance menu. This keeps interface preferences with behavior controls, separate from capability providers. The existing sections retain their shared scrolling surface.

[Apple’s application appearance API](https://developer.apple.com/documentation/appkit/nsapplication/appearance) applies to native windows, controls, panels, and popovers. Setting it to nil restores system inheritance. This keeps SwiftUI and AppKit on the same appearance source and avoids per-window overrides. The preference uses local app defaults because it describes this Mac’s interface, not meeting data.

## Technical debt

None.

## Validation

Captured and compared General before and after the change in an isolated synthetic preview. The final General section sits directly below After Recording in the left column and is fully reachable by scrolling; screenshots confirm the layout in Light and System (dark). Selecting System restores the current system appearance. System starts with the current dark system appearance; Light and Dark update Settings immediately. Keyboard selection of Dark works, and the main window and preview selector reflect the same choice. Light persists after quitting and relaunching and appears in General on reopening. System appearance changes at the operating-system level were not exercised.

`make format-macos`, `make lint-macos`, and `git diff --check` passed. The isolated `make build-macos-preview` release build, which packages the full `make build-macos` output, passed, including the final layout rebuild (152 seconds). Existing linker warnings remain for missing Command Line Tools search directories (`Developer/usr/lib` and `Developer/Library/Frameworks`); no deprecation warnings appeared. Validation used the isolated preview; the installed app and active recording remained untouched. The macOS CI matrix is checked after pushing.
