---
title: Meeting summary title preference
date: 2026-10-03
status: complete
scope: swift-app-ui
---

# Meeting summary title preference

## Problem

Meeting rows displayed two summary lines, including Markdown heading markers. There was no setting to hide this preview.

## Design evidence

Inspected the supplied screenshots and captured the existing meeting list and General settings in isolated Preview. Add “Display summary title on meetings” beneath Appearance in the General group, using the existing switch row. Enable it by default. Show only the summary’s first line, without leading heading markers or whitespace, in one truncating line. Hide the preview and reclaim its row space when disabled. Preserve the selected meeting and viewport when row heights change.

## Implemented solution

General settings and the library view share an app preference through AppStorage. The native list refreshes its cells and heights when the preference changes, retaining its existing viewport anchor. Summary text is derived without modifying saved summaries. A blank first line produces no title. Native cells clear hidden preview text so reused rows and accessibility do not retain it.

At the user's request, the Swift app's AGENTS.md now retains eight core architecture and workflow references. Task-specific worklog links and the exhaustive-index requirement were removed; formatting, platform compatibility, and isolated UI validation rules remain.

## Reasoning

This is a display preference, so it uses the same app-scoped persistence approach as other window preferences rather than changing meeting files or the library schema. A fixed single-line preview avoids width-dependent row heights and keeps the meeting list compact.

## Technical debt

None.

## Validation

The isolated `make build-macos` passed, including packaging and signing. All 20 MarkdownReadingTests and MeetingPrefetchTests passed, covering heading cleanup, first-line boundaries, hidden row height, and viewport preservation when toggling. Formatting, lint, and diff whitespace checks passed.

Captured and inspected Preview in light and dark appearance. Confirmed the enabled default, a single cleaned title line, immediate hiding with reduced row height, restoration when enabled, and persistence of the disabled preference after relaunch. Tab reaches the switch and Space toggles it in both directions. The accessibility tree excludes hidden summary text. Narrow-window and increased-contrast checks were not repeated. The user's running app and library were preserved.

Existing Command Line Tools linker warnings remain for missing Developer library/framework search paths; no deprecation warnings appeared. These paths are outside this change and retain the toolchain-repair follow-up recorded in the build-dependency worklog. The full test suite was not rerun for this display-only change.
