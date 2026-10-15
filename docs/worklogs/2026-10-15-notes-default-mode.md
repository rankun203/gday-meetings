---
title: Notes view defaults
date: 2026-10-15
status: complete
scope: macos-notes
---

# Notes view defaults

## Problem

Saved meetings opened Notes in Edit mode. Reading also observed the meeting collection instead of the current notes draft.

## Implemented solution

Notes opens in Edit mode for the selected recording and Read mode otherwise. The pencil and book controls retain their current layout. The default is captured only when entering Notes: starting or stopping recording while Notes stays open preserves its current mode. Manual choices last until leaving Notes or selecting another meeting. Returning to Notes evaluates the current recording state again. Read mode observes a meeting-specific draft, including checkbox changes.

Opening Read mode loads notes and starts file observation without beginning an editing session or suspending search indexing. Mode changes finish the previous editing session before starting another; canceled transitions cannot start a new session. The editor remains visible while pending image preparation and draft saving complete. A save failure retains Edit mode, and an obsolete transition cannot change the current selection. The parent gives Notes a meeting-specific identity so selecting a different meeting creates a fresh entry. Notes is conditionally present only for the selected tab, so hidden Notes does not run mode transitions. Starting recording no longer navigates away from an already open Notes tab.

## Reasoning

Saved notes should be ready to read. Recording should be ready for immediate entry. Explicit choices remain stable during ordinary content and recording-state updates. A small reading view observes draft changes without publishing the whole meeting collection.

## Technical debt

None added. The existing asynchronous save error handling remains responsible for retaining unsaved drafts when a flush fails.

## Validation

The supplied screenshot and isolated preview capture establish the existing Edit default. Synthetic mode tests passed in root validation; the isolated release build passed in 168.42 seconds. In the isolated Responsive Notes preview, accessibility state and screenshots confirmed recording Notes opens in Edit, saved Notes opens in Read, and returning to a saved meeting resets a previous manual Edit choice. A newly entered checkbox appeared immediately in Read; marking it complete and switching to Edit showed the current checked draft. That earlier build switched to Read after stopping; the subsequent entry-only correction deliberately removes that behavior. Updated mode tests cover entry defaults and manual selection. The corrected isolated release build passed in 121.63 seconds. In the separate Notes Entry Review preview, entering Notes during synthetic recording selected Edit; stopping recording preserved Edit. Switching to Transcript and returning to Notes then selected Read. The revised unit tests were updated but not rerun for this small lifecycle correction; validation used code review, the release build, and the actual tab transitions. Existing Command Line Tools linker search-path warnings remain. A subsequent task-attention indicator appeared during synthetic postprocessing; its cause was outside this mode check. Save-failure UI and rapid overlapping asynchronous transitions were reviewed in code rather than fault-injected in the UI. No main-library interaction was performed.
