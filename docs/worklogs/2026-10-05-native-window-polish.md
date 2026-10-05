---
title: Native macOS 26 window polish
date: 2026-10-05
status: in-progress
scope: swift-macos-design-and-platform
---

## Problem

The first refresh retained a full-width toolbar, repeated headings, and older content controls. The Voice Memos references require column-aligned native chrome, an optional animated sidebar, and quiet reading surfaces. Follow-up reports identified truncated playback controls, mismatched speaker colors, ambiguous histories, lost drafts, and slow selected-meeting sidebar transitions.

## Plan and ownership

1. Capture synthetic before states; establish shared native navigation, controls, and the authorized macOS 26 minimum.
2. Delegate library/search, meeting/player, and settings/platform work in parallel. Preserve the meeting content layout and existing actions.
3. Run independent Codex and Claude Opus audits; distinguish reproduced defects from hypotheses and resolve material product choices with the maintainer.
4. Integrate and validate interactions, full tests, and an isolated release. Save comparisons under `tmp/native-window-polish-2026-10-05/`, then commit, push, and check the macOS CI matrix.

Root owns integration and delivery. The library/search agent owns storage and search; the meeting/player agent owns meeting controls; the settings agent owns platform, provider, and appearance follow-ups. Additional agents investigated history provenance and long-term entity-aware search.

## Implemented solution

- Native sidebar/list/detail navigation serves Meetings, People, and Tags. Tasks, Agents, and Search retain full-width workspaces. The sidebar starts collapsed. Native toolbar Search supports Command-F, and Record sits immediately before it. Repeated headings and the large empty-state recording graphic are removed.
- Package, bundle, native audio builds, tool checks, and current documentation target macOS 26. CI targets macOS 26 and the macOS 27 preview runner. Obsolete platform fallbacks are removed; hardware, language, accessibility, and later-API availability checks remain. Deprecated audio export and application activation calls use supported replacements.
- Transcribe/Re-transcribe menus replace provider-length buttons. Labelings and Transcripts have distinct names and symbols. Native overlay scrolling honors the system visibility preference.
- The main window's native toolbar picker renders the requested rounded gray meeting tabs. Inline segmented and TabView candidates rendered the older bezel and were rejected. The maintainer chose to retain secondary meeting sheets with standard inline tabs; only the main window uses the glass toolbar picker. At narrow widths, native toolbar overflow must preserve access to tabs and Record; final expanded-width acceptance is pending.
- Window-owned bounded sessions retain meeting tabs, list viewports, and directory/task state across destination changes without mounting hidden view trees. An owned native source-list sidebar uses a one-time, explicit focus handoff after navigation; stale outgoing updates cannot cancel a replacement's focus request.
- Provider settings retain explicit Save. A draft coordinator protects edits during provider/tab navigation and quitting; closing Settings retains drafts in memory. Cancel restores the native selection, repair links do not override accepted navigation, and saving one provider does not normalize untouched providers. Navigation does not save credentials or start connection checks.
- Space-key dispatch preserves native control activation. Transcript keyboard selection is visible; transcription confirmations are presented outside menu content; clearing Search exits results. Context-chat Return uses the same availability guard as Send.
- Player track labels use intrinsic width. All Tracks, Microphone, and System Audio remain readable; compact playback menus retain speed, track, and Close Player actions.
- Assigned-speaker menus use the transcript badge's resolved identity, foreground, and pale background. Assign Person remains neutral. Native menu behavior and accessible assignment values remain intact.
- Transcript and speaker-labeling provenance are separate. Transcripts groups actual text versions; Labelings can restore compatible labels without changing words or timing. Legacy snapshots are grouped only when their source, text, timestamps, tracks, and sessions establish compatibility. Full snapshots remain recoverable.

Shared database consolidation, basic voice search, provider streams, and model research are tracked in [Search provider and shared index](2026-10-05-search-provider-index.md). The longer-term natural-language People/Tags proposal is in [Entity-aware voice search research](2026-10-05-entity-aware-voice-search-research.md). Users index their libraries without training; maintainers may train a reusable model after evaluation.

## Performance findings and fixes

Monitoring a large fixture synchronously read 2,400 People/Tags files on the main thread. Refresh now classifies changes, reads affected catalogs off the main thread, coalesces batches, and checks saved/in-memory baselines before publication. Meeting-only events no longer reload all catalogs. A malformed catalog no longer prevents unrelated meeting/task refresh.

Selected-meeting rendering also triggered a projection/save loop. Voice projection could replace a normalized speaker color and return person IDs in speaker order, while folder metadata persisted sorted IDs. Projection now preserves the saved color for the same identity and canonicalizes person IDs. Toolbar rendering reads the loaded snapshot; explicit selection performs reconciliation. The folder round-trip regression failed against the earlier implementation and passes with the fix.

Matched one-line meeting and People sidebar samples ran without accessibility polling. The selected-meeting sample no longer contains the body-time meeting read/save path, and both transitions were responsive. Variation in the control samples prevents a frame-rate or speedup-ratio claim. An earlier 2,400-entry diagnostic recorded no file events over eight seconds and 0.0% sampled CPU, versus 503 events and a 101% CPU sample in the stalled version; this is a diagnostic observation, not a general performance guarantee.

## Header investigation — unresolved

Column reading backgrounds now respect safe-area edges, the meeting list extends under its toolbar, and automatic native insets preserve the first row and scrolled anchor. Controlled captures show the intended blur in some states, but returning from Tasks can restore an opaque backing and hard separator.

Public geometry logs show identical content/safe-area insets and window policy in good and bad states. Explicitly hiding toolbar backing exposed sharp text behind the title. Unified toolbar style, a scrolling-shadow bridge, and owned view-controller containment did not reliably fix the transition. Those unsuccessful appearance/containment changes are not accepted as a fix. The removed bridge source was moved to Trash. No private controller traversal, synthetic blur overlay, or manual inset compensation is used.

Evidence and Claude reconciliation are in `audits/header-reconciliation.md` and `header-geometry/`. A supported navigation-ownership fix remains under investigation. The fixed meeting title/content layout is retained.

Semantic identity around the navigation/toolbar subtree and column-scoped SwiftUI toolbars also failed the controlled header checks. Neither prototype is adopted. The latter still placed Record beside the list actions at minimum width. A standalone AppKit proof with one owned split controller, tracked toolbar sections, and a real detail accessory also retained a hard separator in active initial and scrolled captures. Its Tasks transition exposed an additional prototype layout defect, so it does not justify a production migration. An isolated SwiftUI List control did not establish a matched active-window comparison. No framework root cause is proven. Temporary geometry logging was removed from production source after preserving the evidence.

The user-provided Apple session HAR yielded 376 subtitle cues and eight code examples under `apple-session/`. The focused Claude header review used these public examples and synthetic captures only. It confirmed the distinction between native scroll-view rendering and controller-owned edge policy, but did not establish a tested fix. Full native chrome acceptance remains open.

## Audits and validation

Claude Code's configured Opus resolved to `claude-opus-5-5` for the completed app-wide, header, and history audits. Prompts, raw output, model metadata, and comparisons are retained in `audits/`. Only synthetic captures were supplied. Audit coverage and uncertain hypotheses are recorded; these reports are not exhaustive runtime acceptance.

- Synthetic before captures cover collapsed/expanded selected meetings. The host scrollbar preference is Automatic.
- Native sidebar arrow navigation, both two/three-column focus transitions, and no-focus-stealing behavior pass. Provider Cancel preserves the selected provider and unsaved draft.
- Player labels and compact controls pass at 900 and 1,107 points. Speaker colors and native menu opening/Escape pass at 900 points in light and dark appearance. The original light setting was restored. Increased Contrast is not runtime-validated.
- Main toolbar tabs visually pass at approximately 900 and 1,100 points with the sidebar collapsed. At 900 points with the sidebar expanded, tabs remain reachable through native overflow, including keyboard activation. Notes drafts survive tab and destination round trips. Record remains visible but moves beside list actions at this width, so adjacency to Search is not fully satisfied.
- Synthetic history checks pass: Transcripts shows one This Mac source; Restore Labels selects Original Labels and reapplies Community-1; the current marker updates without changing words/timestamps. Window-clipped captures do not prove full outside-window popover geometry.
- Full serial validation passed 914 tests across 160 suites in 129.989 seconds after two committed-folder consistency defects were corrected. Evidence: `tmp/search-provider-index-2026-10-05/logs/full-canonical-quarantine-tests.log`. The local Python worker's three tests also pass.
- The final isolated release passed in 170.39 seconds using full Xcode, targeted macOS 26 with SDK 27, and passed strict signature verification with no warnings or errors. Five focused tests across three suites passed after the final preview cleanup. The earlier Command Line Tools search-path warnings do not occur with this toolchain. The testable bundle is `tmp/native-window-polish-2026-10-05/production/Gday Meetings.app`; its binary SHA-256 is `9d60083c310e105cba620bbed47462248cbc8f629173a886aa1bdab01b879174`. Final captures, documentation commits, push, and CI are pending.

## CI follow-up

The first pushed run, `37280958588`, passed on macOS 27 but failed on macOS 26 with Xcode 26.6, Swift 6.3.3, and SDK 26.5. The older compiler exceeded its type-checking budget for the fusion-ranking expression and combined toolbar builder. Ranking now uses typed intermediate values; toolbar content is split into named builders without changing its controls or placements. A new regression preserves equal-score ordering before applying the result limit.

The same runner exposed a non-Sendable audio-buffer capture in the existing excerpt converter. A Sendable reference owner now stores the one-shot input in `Synchronization.Mutex`; the callback takes and clears that input under the lock. No `@unchecked Sendable` or `@preconcurrency` suppression was added. An isolated SDK 26.5 compile passed strict concurrency with warnings treated as errors. The combined local build and 20 ranking/audio tests pass; the exact macOS 26 CI rerun remains pending.

## Cleanup

A cleanup agent removed 20 obsolete generated directories before the later instruction to use Trash. Their pre-removal allocated sizes total 54,078,070,784 bytes (about 50.36 GiB), not a measured APFS free-space delta. Those generated files can be rebuilt but cannot be restored from Trash. Source, user libraries, the active isolated build, current production candidate, evidence, and current model/worker caches were preserved. Exact paths and sizes are in `cleanup-manifest.json`.

Subsequent cleanup uses Trash without another confirmation. If a move is mistaken, identify the exact files for the maintainer to restore.

## Reasoning and technical debt

Native navigation should own toolbar placement and sidebar transitions. More decorative material does not repair layout ownership, and a higher minimum OS does not itself fix storage or performance.

Retained compromises and their remediation:

- Two/three-column destination changes recreate native views. Bounded retained sessions preserve user state, but the header transition defect remains open. Resolve native navigation ownership and validate all destination round trips.
- Secondary meeting sheets deliberately retain standard inline tabs, as selected by the maintainer. This is an accepted presentation distinction, not a pending window migration.
- Existing eager startup catalogs, unbounded voice-preparation disclosures and association menus, and full privacy-event replay remain. They are not the paged primary listings. Measure and migrate these consumers to bounded queries/presentation; this update does not claim app-wide constant memory.
- Explicit meeting lookup still reconciles projected metadata outside rendering. Separate read and reconciliation APIs in a later storage cleanup to remove that coupling.
- History retains full text snapshots for backward-compatible restoration. A future format migration can deduplicate them only while preserving all recovery paths.
- Upstream Python model code emits four AMP deprecation warnings during inference. This optional prototype remains unbundled; update the upstream dependency or review a compatibility patch before distribution. The Swift release has no warnings.
