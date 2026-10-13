---
title: Editor save and indexing boundaries
date: 2026-10-13
status: validating
scope: swift-app-editors
---

## Problem

Title completion depended on focus loss and view disappearance. Profile fields saved every keystroke. Notes autosave notifications could start semantic maintenance during an editing session.

## Implemented solution

- Meeting titles retain drafts until Save or Return. Cancel, Escape, and leaving the meeting discard the unsubmitted draft. Native Save and Cancel controls appear only while editing.
- Person and tag short fields stage text until Return or focus loss; Escape discards the active draft. Person notes update memory immediately, coalesce file saves for 500 milliseconds, and flush on editor exit, library change, and quit.
- Meeting notes retain their existing 500-millisecond durability autosave. `NotesStorage` records active editor session tokens so a departing editor cannot release a reopened session; leaving the editor flushes the latest source, releases the boundary, and requests indexing. Read Notes also ends the boundary. The search controller skips meetings within the boundary; its changes are recorded with the search pipeline work.
- Quit persists pending notes. The next launch detects unindexed saved source; quitting does not wait for embeddings.

## Reasoning

Durability and expensive derived work have separate lifetimes. Explicit title submission follows the approved form behavior; short profile fields retain the approved Return/focus-loss contract. The profile debounce uses the existing canonical save transaction and error handling.

## Technical debt

None added. Native focus/disappearance ordering still needs the combined Preview validation described below.

## Validation

Before editing, inspected the running synthetic Navigation Preview (`bac0a13-native-action-working`) using CUA: the title showed an inline native text field without save controls, and Edit Profile showed Name, Email, and Notes in a native popover. Screenshots were emitted in the tool conversation; no private content was copied into fixtures.

Added tests for title typing/focus loss without submission, notes durability while indexing remains deferred, overlapping departing/reopened note sessions, and profile-note flush during quit. Swift formatting lint and `git diff --check` passed. `NotesIndexingBoundaryTests` uses the real autosave, scan, and managed-task pipeline with an injected deterministic encoder and model-readiness check. One scenario verifies no task admission or embeddings while editing, then indexing after exit; another quits with a pending draft and indexes it through a new store on the next launch. The model-readiness dependency defaults to the real model manager. All 110 combined scoped tests passed, including these cases; production builds passed. Post-change Preview screenshots and real Save/Cancel/profile checks remain unverified because CUA reports no accessible window for both Preview and Finder.
