---
title: Search field scrolling
date: 2026-10-07
status: complete
scope: macos-search
---

# Search field scrolling

## Problem

The toolbar search field clipped long queries while editing. Moving the caret to the end did not reveal the remaining text. The existing screen and focused editing state were inspected before implementation.

## Implemented solution

Configured the native field in `LibrarySearchField.swift` to use single-line layout and a scrollable cell. The design retains the field width, search button, clear button, focus ring, and loading indicator; horizontal scrolling keeps the caret visible within the text area.

## Reasoning

Use AppKit's field editor scrolling rather than changing toolbar geometry or adding a custom text editor. Apple's `NSCell.isScrollable` and `usesSingleLineMode` documentation describes the supported behavior.

## Technical debt

None.

## Validation

An isolated SwiftUI preview compiled the actual search field source with a synthetic long query. Screenshots confirmed scrolling to the end and back to the start, typing at the end, and scrolling while the loading indicator is active. Clearing the query restored the placeholder. The clear button remains outside the editable text area. Swift formatting validation and `git diff --check` passed.

`make build-macos` passed in an isolated copy, including signing verification, with macOS 26.0 minimum and SDK 27.0. The first attempt rejected copied module caches because their original checkout path differed; those temporary caches were removed. The successful build reported stale copied-cache paths and missing Command Line Tools linker search paths. It reported no deprecation warnings. The running app was not replaced. The preview does not validate the complete toolbar or search service. No commit or push was made, so CI was not triggered.
