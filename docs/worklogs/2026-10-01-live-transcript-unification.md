---
title: Shared live and saved transcript editing
date: 2026-10-01
status: ready-for-user-testing
scope: swift-transcript
---

## Stable appearance follow-up

The user's later screenshot and report identified changing speaker badge colors. Palette assignment previously resolved collisions against the complete current identity set, so adding a speaker could recolor existing badges. Saved and live rows now use a deterministic identity hash. Live source placeholders use their source and recognition session; detected speakers use their scoped identity, and named people use their person identity. Row IDs remain separate attribution targets.

Visible row equality now gates live display generations. Native updates skip unchanged rows, reload only revised rows when IDs remain in place, and insert or remove trailing rows without rebuilding the table. Structural reordering and width changes retain full reloads. Layout no longer performs a second full reload for every content generation. Changes to voice samples alone do not invalidate the people-name display. Deferred editor and picker updates keep their original callbacks paired with the visible rows until the interaction ends.

Regression coverage checks stable colors after identity insertion, removal, and row replacement, plus no-op and single-row native refreshes. The production native component compiled in isolation, and light and narrow dark captures were inspected under `tmp/live-transcript-unification/screenshots/stable-live-*.png`; wrapping, badge style, and provisional underline remain intact. Strict formatting and diff checks pass. Integrated regression and release checks are recorded by the final validation run.

The eight-color palette can contain collisions between identities. This is an accepted display constraint: preserving an identity's color takes priority over changing existing colors to keep the current set distinct. Text and person labels remain the identity cues. No periodic refresh timer was added.

Finalized and provisional rows now share one resolved presentation snapshot per refresh. This removes duplicate full-transcript attribution work while retaining checkpoint and speaker cursor updates. A missing live provider produces one setup message; voice-matching failures remain visible separately when anonymous labels are working.

**Technical debt:** Checkpoints still encode the growing draft on the main actor every two seconds. This existing persistence path is separate from the fixed table reloads. A future long-recording profile should measure its cost before moving writes to a serialized, revision-aware worker with an explicit stop flush; independent background writes could otherwise overwrite newer checkpoints.

The integrated suite passed 581 tests in 106 suites, including the temporary production-view capture. Final review caught a stale playback highlight on an untouched cell after another row's timestamp changed. Clearing the old highlight before partial row updates fixed it; all 63 focused transcript tests then passed, including a visible-cell regression. Synthetic captures cover light/dark layouts and unavailable-provider controls. These checks do not replace a continuing real recording, keyboard/VoiceOver review, or model-accuracy evaluation; the user's running application was not restarted.

The final isolated `make build-macos` release passed in 126.79 seconds with successful bundle signing and property-list validation. The 277-file application snapshot matches the final source tree. Formatting, lint, and diff checks passed. Existing Command Line Tools library/framework search-path warnings remain; no deprecation warning was emitted. The preceding commit passed all three hosted macOS runners; the new commit's matrix is checked after pushing.

# Shared live and saved transcript editing

## Problem

Live text used a separate SwiftUI stack with larger row spacing, source and Draft subtitles, and a red word trail. Saved text used a compact native table with speaker badges and editing. During recording, users could neither correct text nor assign a person to a passage.

## Implemented solution

Live text now uses `NativeTranscriptView`, including its timestamp column, compact speaker badges, native selection, text editor, contextual actions, and person picker. Provisional text uses a subtle underline. Unassigned live badges show `mic_01` or `sys_01`; assigning a person affects the selected passage, not every passage from that audio source. Read-only libraries disable editing, and live rows do not offer playback.

Selecting a passage, opening its context menu, editing text, opening the person picker, or scrolling disables live following until the user selects **Follow Live**. Incoming row and layout updates coalesce while an editor or picker is open, preserving the active field editor and captured save target. Saved playback retains its existing following behavior.

Manual text and person changes are stored separately from recognition results in the live checkpoint, anchored by source, session, and time range. Presentation reconciles replacements and timed splits without discarding manual changes. When word timing cannot resolve an overlap safely, both passages remain visible with an explanatory caption. User-authored text is not presented as a recognition result. Adoption into the saved transcript preserves text and per-passage assignments. Unadopted checkpoints also show speaker badges and support assignment through adoption.

The synthetic recording preview contains 18 finalized passages, a wrapped passage, two provisional passages, and one assigned person. It uses the production renderer without capture or inference.

## Reasoning

The supplied live and saved screenshots established the layout difference before implementation. The design reuses the saved table directly, with the same compact geometry and gestures. A provisional underline replaces the live-only source subtitle. User testing subsequently restored the red trail alongside it. Stable passage identity and separate manual overrides are needed because recognition can replace or split text after a user starts editing. Coalescing visible updates during an edit prevents AppKit from ending its shared field editor on every recognition refresh.

## Validation

Offscreen production-component captures were inspected with an assigned synthetic person, unassigned microphone/system badges, and underlined provisional text. The person-picker content was checked in light and dark appearances, including **Apply to This Speaker**, its scope explanation, current-person checkmark, search field, and removal action. These captures do not exercise a live native popover window, actual recognition, or full mouse/keyboard event delivery. A narrow capture exposed and verified the table-column-width correction for wrapped text.

Focused regressions cover provisional underline removal, native badge mapping and independent assignment targets, editor preservation across live updates, and explicit follow resumption. Backend regressions cover persistent manual overrides and recognition reconciliation. Scoped Swift formatting and diff checks pass. The integrated sequential suite passed 569 tests in 106 suites. Final production-component screenshots were inspected; the source-matched release build passed in the isolated checkout. No real recording or user library was opened for this change. Preview cannot establish recognition accuracy, audio capture, or hardware finalization behavior.

## Technical debt

Live overrides retain unresolved overlaps when word timing is unavailable rather than guessing a split. This can display both manual and recognized text for the same time range; the UI explains the overlap. Future reconciliation needs sufficient timing evidence or an explicit user resolution action. Visible recognition updates pause while editing or assigning a person; the latest state is applied when the interaction ends. This deliberate interaction tradeoff avoids replacing an active native editor. Existing source-level labels are not speaker diarization; automatic speaker providers are covered in the local-speaker-providers worklog.


## User validation follow-up

The user's recording screenshot showed that provisional text had lost the earlier red word trail. The shared renderer now keeps the provisional underline and restores red on the two most recent words, using the existing recognition timing/token selection. Finalized and manually edited text clears the trail. This preserves the compact layout and editing behavior. The current screenshot supplied by the user is the before-state evidence; synthetic production-component captures validate the changed styling without touching the active recording.

Light and dark production-component captures show the restored red trail with unchanged row geometry. The existing cell regression verifies that provisional text receives red and finalized text clears it. The final sequential suite passed 571 tests in 106 suites, including the download correction. A follow-up also refreshes label visibility immediately when toggled and treats deleted People as unassigned without altering stored identities.
