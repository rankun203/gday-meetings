---
title: Conditional task status bar
date: 2026-09-28
status: complete
scope: swift-app-ui
---

# Conditional task status bar

## Problem

The bottom status bar reserved a full row for “No active tasks,” reducing space for meeting content when there was no work to show. The isolated Preview baseline confirmed this below the player.

## Implemented solution

`MeetingStore.showsTaskQueueStatus` includes queued, running, and failed managed tasks plus other background jobs. `LibraryView` conditionally inserts only the bottom status button, with a 150 ms opacity transition disabled for Reduce Motion. Completed and cancelled history does not keep the bar visible. The Tasks sidebar and player remain independent.

## Reasoning

The existing task summary defines the useful visibility states. Keeping the same parent and transcript identities avoids resetting navigation or transcript scroll position when the bottom row changes. The UI design document now records this rule.

## Technical debt

None.

## Validation

- `make format-macos`, `make lint-macos`, and `git diff --check` passed. `make build-macos-preview` passed, updating the development full and Preview bundles. Existing Command Line Tools linker warnings about missing Developer framework/library search paths remain; no new deprecation warning appeared.
- In isolated Preview, the empty queue has no status bar and retains the player and Tasks sidebar. The synthetic queue shows its running/queued/attention summary, and clicking the status opens Tasks. After stopping the running tasks and removing queued work, the attention-only bar remains. Dismissing both failed tasks removes the bar while the three cancelled tasks and completed task remain visible in history. Screenshots confirm both empty and history-only layouts.
- Validation used System appearance (light). Dark appearance, keyboard traversal, Reduce Motion, and transcript scroll anchoring during an asynchronous task completion were not exercised in this narrow change. The implementation leaves transcript identity and scroll state intact; this is a code-level design property, not a completed visual scroll test.
- The regular app was not modified or quit. No provider work or audio capture was started.
