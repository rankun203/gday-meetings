---
title: Navigation loading and transcript anchoring
date: 2026-10-07
status: implemented
scope: macos-navigation-transcript
---

## Problem

Cancelling the sole caller of a cold meeting load left its shared read eligible to publish. Rapid navigation could start concurrent reads. Restoring a cached short transcript revision above the viewport changed row geometry before capturing the reading position.

## Implemented solution

Meeting loading records cancellation synchronously for each consumer. Shared operations retain demand from other pages and background jobs. A cancellation-aware queue bounds cold reads to one; cancelled queued operations release their waiters, and abandoned results cannot publish. Request and library generation checks continue to reject deletion and library-change races.

Transcript row backgrounds now use the native reuse queue, matching the meeting list. Allocation profiling found that creating a background for every row request retained 1,573 backgrounds during repeated anchor corrections; reuse reduces this to 24.

Transcript updates capture the visible row ID and pixel offset before replacing row data or applying cached heights, and restore that position after targeted table updates. Explicit navigation and active live following retain their existing behavior.

Both supplied reproductions are promoted into the main test suite. A rapid-navigation regression checks that 20 page selections perform only the held read and the final requested read, with no abandoned publication or remaining operation entries.

## Reasoning

Cancellation belongs to individual callers, so cancelling one page cannot cancel a background consumer's shared read. A synchronous file read already in progress cannot be interrupted safely; it occupies the single read slot until completion, and its result is discarded when no consumer remains. UI geometry must be captured before any immediate cache hit can change it.

## Design and Preview evidence

Before editing, inspected the isolated Preview at `tmp/voice-startup-validation/apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`. Its banner identified `759e6fc-dirty`; the light-appearance screenshot was 2218 × 1324 pixels. The transcript showed timestamp, speaker, and text columns with playback controls below. Intended design: preserve this layout and its controls, keeping the reader's top passage and offset stable while text above it changes. The automated 100-row fixture exercises the offscreen revision case more precisely than this ordinary Preview fixture.

After implementation, inspected `tmp/navigation-validation/navigation-preview/Gday Meetings Navigation Preview.app`, copied from the validated release with a unique Preview bundle identifier. Its banner is `198abb5-navigation-fixed`; the release was built at 2026-10-07 10:01 UTC. Executable SHA-256: `f889648f7a367698bc42cec58d44f524338a70425da1d72e756eb42d752c95a7`. Standard synthetic fixtures, silent playback, and no Keychain or capture were used. Captures in the task's UI-tool output show both dark and light appearance. The final window was larger than the baseline, so the screenshots establish control/layout consistency rather than a pixel-matched benchmark.

Checked selecting both meetings and returning, opening the transcript editor, typing generic replacement text and cancelling with Escape, arrow-key row selection, and starting/pausing silent playback. The original passage remained intact after cancellation and navigation; timestamp, speaker, and text columns and fixed controls retained their layout. Closed only this validation Preview afterward. Live following, long-table cache reuse, and exact offscreen anchor preservation were checked by automated tests, not manually reproduced in the three-row Preview. Real capture, hardware playback, and presentation-frame timing were not tested.

## Validation

Both promoted reproductions pass. Re-running the original transcript implementation from `198abb5` with the promoted test reproduces the changed top row and exactly 27 pixels of offset error. The revised loader passes shared-consumer cancellation, external-change retries, abandoned-page publication, rapid navigation, and queued deletion/library-generation checks. The 20-selection test performs two physical reads, keeps only the active read and final pending request, completes cancelled queued callers before releasing the held read, and drains its operation table.

Final validation in `tmp/navigation-validation` passed: 50 navigation/geometry/cache tests, 10 live-transcript tests, 17 live-editing tests, and 34 native transcript interaction tests (111 across the focused runs). The interaction suites cover overlapping playback highlights, paused seeks, active editors, keyboard selection, frozen live rows, and live-follow pause/resume. `make format-macos`, `make lint-macos`, and the scoped diff whitespace check pass. `make build-macos` and `make build-macos-preview` both passed packaging and signature verification, with macOS 26.0 minimum and SDK 27.0. No running development bundle was replaced. The initial build needed permission to use the compiler's nested sandbox. Toolchain linker warnings reference missing Command Line Tools search directories; no deprecation warning was found. No push or CI run was requested.

Two broad parallel runs had intermittent failures in `stopRetainsDetachedSessionFinalPhrase` and `manualLiveEnrollmentPreservesTypesAndClearsReassignedContributions`, respectively. Both passed in earlier runs. One run overlapped allocation export; a quieter run still failed the enrollment case. These results do not establish a new voice-startup defect. Both cases passed in the final focused suite runs. The broader concurrent runs are not represented as clean passes.

Claude Code review was attempted with its Opus alias and explicitly with `claude-opus-5-5`. Both attempts returned the account's monthly spending limit before review. No findings or model identity were returned; this is not a completed independent review.

### Matched performance measurements

The opt-in `NativeTranscriptGeometryTests.warmRevisionPerformance` uses 1,000 synthetic rows and 240 alternating cached short/long revisions above the viewport. Run with `GDAY_TRANSCRIPT_REVISION_PERFORMANCE=1 bash apps/client-macos-swift/scripts/test-macos.sh --filter warmRevisionPerformance`. Three fresh, unprofiled Debug test processes were run for each implementation. The baseline differs only by restoring `NativeTranscriptView.swift` from `198abb5`; dependencies, other source files, fixture, column width, and operation count match. Post-change values below include native row reuse. macOS 26.6.2 (25G83), Apple Silicon, Swift 6.4, SDK 27.0, Instruments 27.0.

| Metric | Reviewed implementation | Final implementation |
| --- | ---: | ---: |
| Anchor changes per 240 updates, each run | 240 | 0 |
| Process CPU, median seconds | 4.003 | 1.718 |
| Main-thread CPU, median seconds | 3.965 | 1.695 |
| Update duration p95, median milliseconds | 7.983 | 6.872 |
| Callback gaps over 100 ms, all three runs | 1 | 0 |
| Live heap growth, median bytes | 1,726,128 | 511,936 |
| Additional text measurements, each run | 30 | 0 |
| Cache entries after workload | 79 | 49 |
| Peak pending measurements / bytes | 28 / 4,256 | 28 / 4,256 |
| Pending measurements at completion | 0 | 0 |

Separate Allocations captures completed all 240 operations in both versions. Their whole-process totals include test startup and fixture setup, so they are not per-update counts:

| Allocations metric | Reviewed implementation | Final implementation |
| --- | ---: | ---: |
| Heap allocation count | 13,224,057 | 9,146,932 |
| Cumulative heap bytes allocated | 2,135,644,592 | 1,351,791,264 |
| Persistent heap bytes at trace end | 6,117,664 | 4,999,616 |
| Transcript row backgrounds allocated | 2,767 | 24 |

The existing fresh-table test also passes with 10,000 rows: zero measurements in all height-delegate calls, 19 cold measurements, zero additional measurements for a new warm table, peak pending count 15 and 2,805 bytes, and estimated cache size 12,160 bytes.

These are callback/layout and allocator measurements, not presented frames or key-to-photon latency. Debug timings do not establish release performance or 120 Hz rendering. The baseline's anchor drift also changes the viewport, which explains its extra measurements; both runs still apply the same requested revisions. Instruments overhead is excluded from CPU and callback comparisons. Heap snapshots measure live allocator state, not cumulative allocation traffic; the separate trace table supplies cumulative totals. The first anchoring-only candidate retained more row backgrounds; native row reuse resolved that increase before the final measurements.

Raw logs, exported allocation tables, and `performance-summary.json` remain in ignored `tmp/navigation-validation`. All five newly generated trace bundles, including two failed test-launch captures, were deleted after validating exports and completion logs. Existing user traces and videos were untouched.

## Technical debt

The existing synchronous meeting-file reader remains non-interruptible during a read. Serialization bounds its resource usage, but the latest selection may wait for that read to finish. A future chunked, cancellation-aware storage reader could reduce this latency if measurements justify the added complexity. No schema or compatibility bridge was added.

## Notes

Other agents' uncommitted model lifecycle and task/resource work is preserved. Loader state is the only overlapping edit in MeetingStore. The isolated snapshot includes their work present when validation began. A later independent `removeIndexNamespace` migration call was added to MeetingStore in the main worktree during validation; it was preserved and is outside this release snapshot. The loader state and the other four changed Swift files match the validated copy. No commit or push was made. Existing user traces and videos are untouched. No voice-startup correctness defect is claimed; later main-thread embedding reads and writes remain outside this task.
