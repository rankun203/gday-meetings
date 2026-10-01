---
title: Reopen Meetings from the Dock
date: 2026-09-28
status: superseded
scope: swift-window-lifecycle
---

# Reopen Meetings from the Dock

This initial Dock-only change is extended by [Window activation](2026-10-01-window-activation.md), which records the current lifecycle policy and validation.

## Problem

Clicking the Dock icon after closing all windows did not reopen Meetings. The app delegate had no reopen handler.

## Implemented solution

The main scene supplies its existing SwiftUI window-opening action to the application delegate. When a Dock reopen event reports no visible windows, the delegate opens the singleton Meetings scene and marks the event handled. Otherwise, AppKit retains its normal window activation behavior, including minimized windows.

## Reasoning

The existing Preview accessibility state showed one Meetings window with the library sidebar, toolbar, and playback controls. The intended interaction restores this same scene after closing it, with no layout or control changes. Screenshot capture timed out before implementation; visual comparison remains pending.

Using the existing singleton scene preserves the shared store and playback objects and avoids constructing a separate AppKit window. The retained opening action remains available after the view closes. Apple's [reopen delegate documentation](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)) describes Dock activation and the handled-event return value.

## Validation

The release build and signed Preview packaging passed, along with formatting, lint, and diff whitespace checks. The initial sandboxed build could not invoke SwiftPM's sandbox; the retry with build access succeeded. No deprecation warnings were reported. The linker still reports two missing Command Line Tools search directories (`Developer/usr/lib` and `Developer/Library/Frameworks`); these are existing toolchain warnings. Repair or update the Command Line Tools installation and rebuild to resolve them.

Preview screenshot capture and Dock access repeatedly timed out in UI automation, so actual Dock close/reopen behavior, minimized-window activation, repeated clicks, and visual comparison remain unverified. The installed regular app was not replaced. The change is available in the rebuilt development and Preview bundles.

## Technical debt

None.
