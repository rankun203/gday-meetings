---
title: Compact speaker assignments
date: 2026-10-03
status: complete
scope: swift-app-ui
---

## Problem

The expanded Speakers section repeated its heading, grouped speakers beneath provider headings, and split each label and person assignment across two lines. The user requested one row per assignment.

## Implemented solution

Each speaker uses one horizontal row: its label and an assignment menu showing the current person or **Assign Person**. Provider and audio-source details appear in the label tooltip. Empty labels display **Unlabeled**. Existing assignments to source placeholders retain their person name and **Remove Assignment** action. Assignment, reassignment, new-person creation, and removal keep their existing actions.

## Reasoning

The disclosure already labels the section. Provider and track metadata do not need separate rows for choosing a person. A bounded menu width and single-line labels preserve the compact layout. Accessibility exposes the assigned person separately from the assignment action.

## Technical debt

None.

## Validation

Before editing, inspected the supplied screenshot and captured the expanded section in the isolated synthetic preview. The existing preview showed the duplicate heading and multiple lines per speaker. Updated screenshots confirmed one line per assignment in System, Light, and Dark appearances, in restored and maximized windows. Verified reassignment, removal, keyboard selection in the person menu, and scrolling to remaining rows. The assigned name updates in place; removal returns the menu to **Assign Person**. New-person creation, very long names, VoiceOver speech, and inactive-window appearance were not exercised.

`make format-macos`, `make lint-macos`, and `git diff --check` passed. The isolated `make build-macos-preview` completed its production release build in 59.71 seconds and packaged the preview. Existing Command Line Tools linker search-path warnings remain; no deprecation warnings were reported. No additional tests were added for this layout-only change. The installed app and real meeting data remain untouched.
