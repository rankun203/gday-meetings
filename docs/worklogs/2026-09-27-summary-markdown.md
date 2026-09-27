---
title: Read-only Markdown summaries
date: 2026-09-27
status: implemented
scope: swift-app-summary-ui
---

## Problem

Summary displayed generated Markdown in an editable text field, exposing heading and list syntax. The user requested the same rendering as Notes in a read-only view.

## Design before implementation

Inspected the supplied Summary screenshot and the coordinator's isolated Preview inspection of Notes reading mode. Retain the Summary heading and Generate Summary or Regenerate Summary action. Use the Notes reader's quiet rounded panel, heading hierarchy, lists, inline formatting, and selectable text. Omit the Notes editing toggle and timestamp gutter because Summary is always read-only.

## Implemented solution

Extracted the existing Notes reader as `MeetingMarkdownReadingView` in `MeetingNotesWorkspace.swift`, accepting Markdown, an empty-state message, and timestamp visibility. Notes retains its existing playback controls and reading layout. `MeetingDetailView.swift` uses the shared reader for Summary and removes its obsolete text-editor helper. Reading does not modify stored summary text.

## Reasoning

Sharing the existing renderer keeps Notes and Summary formatting consistent without adding a dependency or a second Markdown implementation. Summary text remains selectable and scrollable. An empty summary explains the Generate Summary action.

## Validation

Reviewed changed wording against the writing guide. The full suite passed 320 tests in 66 suites. Isolated Preview screenshots confirm rendered headings, bold text, lists, tables, and task checkboxes in System (dark) and Light appearance, including a narrower window. Summary exposes static text and scrolling instead of an editable field. The generated-content action and panel remain in place. Full keyboard selection, VoiceOver, explicit Dark selection, and minimum-OS validation were not exercised.

## Technical debt

Retains the Notes reader's existing limited Markdown support: unsupported nested structures and HTML remain literal source. This avoids adding a parser dependency for rendering parity. If broader Markdown support is required, adopt a source-range-aware parser for both views and retain safe literal fallbacks.

Build and formatting validation used `make format-macos`, `make lint-macos`, and `make build-macos-preview`. The known Command Line Tools missing-library/framework search-path warnings remain; no new deprecation warning was observed. Remediation remains tracked in [the toolchain worklog](2026-09-25-swift-keychain-deprecations.md).
