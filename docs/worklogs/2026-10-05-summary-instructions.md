---
title: Summary instructions and responsiveness review
date: 2026-10-05
status: complete
scope: swift-app
---

## Problem

An earlier installed build became unresponsive during summary generation. Playback and regeneration were difficult to control. The Summary action also lacked instructions for a single request, such as selecting an output language.

## Findings

Evening changes address plausible causes, without establishing the cause of this incident:

- `58f5985` (18:52): voice projection preserves normalized colors and person ordering, avoiding repeated reconciliation saves.
- `0c04ea8` (18:49): catalog refresh coalesces changes and reads People/Tags off the main actor.
- `2d4d9c0` (18:57): rendering reads loaded meeting snapshots. The prior diagnostic reproduced a main-thread catalog scan and a projection/save loop.
- Earlier workspace changes bounded task history and removed synchronous journal writes from progress updates.

The newer build contains these fixes. No incident stack sample or exact earlier binary revision is available, so this review cannot guarantee that summary generation will never stall.

## Design evidence

Inspected the supplied older screenshot and captured the installed app's Summary screen through computer use before editing. The current action sits at the upper-right of the Summary reading area, below toolbar tabs. Keep that placement. Holding Option changes its label to “Regenerate Summary with Notes…”, or “Generate Summary with Notes…” when empty. Present a native sheet with a labeled multiline User Instructions editor, a language example, Cancel, and the appropriate generation action. Focus the editor initially; disable submission for blank instructions or unavailable generation.

## Implemented solution

The Summary button uses SwiftUI modifier-key observation and a native sheet. A named accessibility action opens the same editor. Instructions are stored on the managed task as an optional Codable field, retained on Retry, passed through image-aware prompt preparation, and appended under User Instructions with explicit precedence over default language and formatting. Data-transfer receipts identify User Instructions. Normal generation clears request-specific instructions. Meeting notes and provider preferences remain unchanged.

## Reasoning

Task-owned instructions preserve request intent through queueing and recovery without changing global provider behavior. Optional decoding keeps existing journals compatible. Reuse the existing scheduler, completion checks, and saved-summary protection. Apple's supported [modifier-key observation API](https://developer.apple.com/documentation/swiftui/view/onmodifierkeyschanged%28mask%3Ainitial%3A_%3A%29) avoids a separate event monitor.

## Technical debt

None introduced. Existing responsiveness limits and the absence of incident diagnostics remain; no speculative performance fix was added.

## Validation

All 41 targeted tests in seven suites passed serially in 5.920 seconds: summary prompts, streaming, images, performance, draft publication, automatic summaries, and task recovery. New assertions cover override precedence, blank input, unchanged meeting context, optional-field compatibility, actual loopback request and receipt, failed-request Retry, and clearing instructions for ordinary generation. Existing cancellation and playback-route-change tests pass.

The final release compilation passed in 157.72 seconds with no warnings; packaging verified macOS 26 minimum, SDK 27, and strict signatures. Formatting, lint, and whitespace checks pass. Validation uses macOS 26.6.2 and Xcode Swift 6.4. Only the Applications copy was running before builds, so no development bundle or user recording was replaced. Build and test logs and the source diff are retained under ignored `tmp/summary-instructions-2026-10-05/`. The release bundle is `apps/client-macos-swift/.build/macos/Gday Meetings.app`. At this validation checkpoint, it had not been installed or pushed; CI had not run for the uncommitted changes.

Synthetic UI validation used the rebuilt `.build/preview/Gday Meetings UI Preview.app`, revision label `40e64af-summary-instructions`, with no extra fixtures. Captures in the tool session show the 900-point window and 480-point sheet. Light and dark sheets match the design: readable wrapping, editor focus, multiline entry, disabled blank submission, and enabled nonblank submission. Escape cancels; reopening clears the cancelled text. Submission closes the sheet and creates the expected failed task when no provider is configured, preserving the existing summary. The ordinary button is reachable with Tab.

Option-Space and Option-Return did not activate the native button; these are not advertised shortcuts. The automation API does not expose a held-modifier mouse click, so the named accessibility action validated the shared sheet path. Physical Option-click and the held-key label transition remain unverified. Wider-window, System appearance, and VoiceOver speech were not separately tested. No real provider generation or original-incident reproduction has been performed.
