---
title: Immediate transcript playback and assignable speakers
date: 2026-10-24
status: validated
---

## Problem

Test14 Run 2 showed roughly 600 ms between initial transcript mouse handling and the playback request, followed by approximately 115 ms of main-thread UI work before transport seeking. The native single-click handler deliberately waited for the double-click interval. Seeking then stopped and reset the audio engine and resumed through the main actor. Sample timestamps establish scheduling evidence, not precise audible onset.

New independent-turn results could display named transcript passages while hiding the entire Speakers panel. Panel eligibility required a speaker-level voice embedding, which these results do not retain.

## User Intention

Start playback immediately on transcript clicks, including the first click of a double-click editing gesture. Allow audio to start when ready while the UI updates. Reuse the engine for seeks within the same meeting. Show assignable speakers even without recognition evidence; gate recognition actions on their actual evidence. Preserve existing assignment scope, turn-specific corrections, and previous trial decisions. Deliver the next isolated test app.

## Design and reasoning

The supplied screenshot shows the missing disclosure below a transcript containing detected speaker labels. Inspection of the running Test15 app confirmed the existing player placement; the user changed its selected tab during inspection, so the supplied transcript screenshot remains the relevant before-state evidence. Keep the current panel layout, with labels on the left and assignment controls on the right. Distinguish differing passage identities rather than inventing one identity for a shared label.

Remove the deliberate gesture timeout while retaining double-click editing and speaker selection. Queue audio work before publishing expensive UI changes. Pause and resume the prepared engine around buffer replacement, preserving its setup while maintaining render-thread safety.

## Implemented solution

Implemented in the isolated Test15 source checkout and integrated into the main workspace while preserving unrelated work. Native transcript clicks invoke playback immediately. The transport queues combined seek/resume before UI publication and explicit Play queues behind an in-flight seek; Pause remains ordered after earlier commands. Intent/revision checks prevent stale callbacks from overriding newer actions. Same-meeting playback avoids redundant title and excerpt publications. Seeking pauses the engine and clears only time-pitch audio history before resetting the ring, retaining prepared graph resources.

The panel uses assignable canonical speakers independently of recognition embeddings. Derived machine turn projections are deduplicated against canonical labels; explicit passage corrections remain separate. A single-pass assignment summary displays uniform names with tentative status, mixed identities as “Varies by Passage,” and removal wherever an effective assignment exists. Help describes whole-label scope and preservation of individually corrected passages. Checkpoint adoption behavior is retained.

## Technical debt

None. Engine pause/resume uses the existing serial transport queue and quiesces the render consumer before the existing single-producer/single-consumer ring reset. A fully running graph with buffer swapping was rejected because it requires additional synchronization and still needs to clear old time-pitch audio. No schema migration or duplicate assignment state was added.

## Validation and handoff

Prepared an independent copy of the latest 20 completed Test15 meetings and 3,007 voice examples. Shared-lock capture, source metadata checks, and full hashes verified consistency. Pending jobs, Undo history, disposable indexes, and incomplete captures are excluded; remote providers and automatic processing are disabled. Existing apps and libraries remain untouched. Private fixtures and packaging scripts are ignored under `tmp/review-test16/`.


Independent review found and resolved Play being lost during a pending paused seek, stale seek/start failures overriding newer playback intent, and incomplete uniform/mixed projected-assignment display and removal. Follow-up found no remaining source blockers. Regression coverage was strengthened to require actual playback progress after Play, successful transport completion while the main actor is busy, and no audio from the old position after seeking. The initial 59-test playback/native run passed. The final supported-script run passed 147 tests in 16 suites, including playback/Opus/deferred requests, native transcript/geometry, panel eligibility, passage assignment/persistence, projection, and scoped recognition status. Isolated and main-workspace formatting checks and whitespace checks passed. An intermediate direct Swift test invocation omitted the required toolchain macro plugin and failed compilation; the repository-script run supersedes it. The first release build passed. Native preflight confirmed the restored panel and mixed-assignment removal controls, then exposed a double-click targeting regression: immediate playback auto-scrolled the transcript between clicks, opening a different row for editing. The preflight bundle is preserved in ignored storage; the corrected coordinator defers automatic following through the double-click interval while capturing the exact displayed and constituent row identities. Deferred following survives layout/measurement work, resumes for a stable active row, and is cancelled by user scrolling, editing, popovers, source changes, and teardown. Captured identities are validated before editing after replacement. Four regression cases were added and independent follow-up review found no blocker; the replacement passed all 147 tests in 16 suites and formatting/whitespace checks. The replacement release and native recheck passed. No transcript edits were saved.

Apple documents that `AVAudioEngine.pause()` stops hardware while retaining prepared resources; `stop()` releases resources. See [pause](https://developer.apple.com/documentation/avfaudio/avaudioengine/pause()). This change reduces avoidable work; no measured audible-latency claim is made from compilation or sampled CPU timestamps.


Final delivery: Test16 `027db65-test16-3884e13c` is packaged and signature-verified under ignored `tmp/review-test16/`. Release validation passed with macOS 26 minimum and SDK 27. Native screenshots confirmed the expanded panel for independent-turn labels without vectors, mixed assignment presentation, and removal menu availability. Cold-start and warm double-clicks both played and edited the intended constituent; Escape cancelled editing, single-click seeking moved playback, and Pause stopped it. The app is left open and paused with Speakers expanded. Full comparisons against the baseline verified that native checks changed no meeting-content files. Runtime open-file inspection, bundle environment, executable hash, and revision verified the isolated Test16 library and exact delivered binary. The reproducible baseline and earlier preflight bundle remain preserved.

Limits: precise audible onset and hardware-output latency were not benchmarked after the change; native observations establish interaction behavior and advancing playback, while offline render tests verify audio content boundaries. Existing Command Line Tools linker warnings for missing Developer/usr/lib and Developer/Library/Frameworks remain; no new deprecation warning appeared. Source is uncommitted alongside preserved concurrent work; no push or CI run was requested.
