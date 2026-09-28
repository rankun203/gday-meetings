---
title: Summary task isolation and playback route changes
date: 2026-09-28
status: complete
scope: swift-app
---

# Summary task isolation and playback route changes

## Problem

A device-change notice appeared while playback was paused, near a summary that appeared incomplete. The playback engine reported every configuration change as an interruption, including a prepared, paused item. Inspection found that summaries already run as store-owned, journaled tasks with separate scheduling and progress; playback has no cancellation path to them. A scoped, read-only check found completed summary jobs, not cancelled jobs. Historical request inputs were not retained, so the original short answer cannot be attributed to a device change.

The completion transport rejected truncated event streams but accepted an explicit incomplete finish reason in a JSON response. A request could also save a result after its input transcript or notes changed.

## Implemented solution

- `StreamingPlayback` marks its engine for replacement on a configuration change. Only interrupted active playback produces a notice. `MeetingPlayback` rebuilds on the next explicit Play, retaining the current position.
- The existing independent task ownership and asynchronous networking remain. Tests cancel a caller and deliver a playback configuration event during an in-flight summary; the journaled summary must still finish and save.
- JSON completion responses with an explicit finish reason other than `stop` fail without replacing the previous saved summary. Compatible providers that omit the field remain supported.
- `performSummary` checks the transcript and notes snapshot before committing. Changed input produces an actionable task error and preserves the saved summary. The existing pending automatic-summary mechanism can then process newer transcripts. Manual notes-only summaries remain supported.

## Reasoning

An asynchronous network task does not need a dedicated operating-system thread. Apple documents [Task lifetime](https://developer.apple.com/documentation/swift/task/) independently of retaining a task reference. Its [engine configuration notification](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange) requires the app to restore appropriate connections after hardware format changes and cautions against tearing down the engine inside the notification callback; the existing serial playback queue remains responsible for teardown. The store already owns summary lifetime independently of the view and playback engine. Preserve that design and test its boundaries. Separate engine invalidation from the user-facing interruption notice so paused items can recover without suggesting that playback was running.

Before implementation, isolated Preview showed a paused player with its Play control. Keep the same layout, controls, and paused state. Only an actual interrupted playback session should add the device-change notice.

## Technical debt

Historical request input versions are not persisted with summary task records. This limits diagnosis of an older short summary; a future bounded input manifest could record source revision and counts without retaining content. This change prevents saving against changed input but does not add a persistent source revision schema. Compatible JSON responses without a finish reason remain accepted because existing providers omit it; a provider capability contract would be required to make that field mandatory.

## Validation

The focused `SummaryStreamingTests`, `BackgroundJobTests`, `StreamingPlaybackTests`, `MeetingPlaybackTests`, and `AutomaticSummaryTests` suites passed, including both paused and active route cases, caller cancellation during streaming, explicit stop/cancellation, changed source input, and JSON truncation reasons. `make format-macos` and `git diff --check` passed. Existing Command Line Tools linker warnings report missing Developer framework/library search paths; no deprecation warnings were reported. Updating the installed toolchain is the follow-up for those search paths. Automated coverage uses synthetic content and a loopback provider; no real meeting data is sent. After the integrated Preview build, a captured screenshot showed the unchanged persistent player with “Paused,” the Play control, and no device-change notice. Hardware AirPods switching is not exercised. The installed app and its running tasks remain untouched.
