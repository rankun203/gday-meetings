---
title: Readable transcript passages
date: 2026-10-15
status: implemented
scope: macos-transcript-presentation
---

# Problem

Listening review found that speaker turns were useful, but unresolved words and punctuation appeared as many short rows. The existing screen was captured before implementation, including the paused playback state.

# Implemented solution

Reading passages compose adjacent canonical segments in the existing timestamp, speaker badge, and text columns. Trailing unresolved text continues under the preceding recognized passage until a sentence boundary or another speaker's acoustic evidence. Track, source, session, manual assignments, and unaligned edits remain boundaries. The canonical text, timing, and attribution remain unchanged.

Each displayed passage retains its constituent row identifiers and text ranges. Playback and review navigation resolve those identifiers. Editing and speaker assignment expand the passage first, preserving the existing segment-specific actions. Expanded passages stay expanded for the selected transcript so draft edits are not collapsed. Accessibility help identifies unresolved words within a composed passage.

Parent review also found that canonical acoustic grouping could cross a live transcription session restart. All canonical merges now require matching source and session.

# Reasoning

Presentation grouping improves reading without assigning uncertain words to a speaker in summaries, exports, or voice review. Source anchors preserve original spacing where fragments were contiguous. Sentence detection uses the platform tokenizer. Composition applies only to current saved labels, not a live checkpoint with different provenance.

# Technical debt

No production shortcut introduced. Expansion before editing is an intentional interaction: a composed passage contains several independently editable segments. Existing alignment and voice-library transaction limitations remain documented in the diarization projection worklog.

The existing geometry fixture retains a timing-sensitive assertion that table width stays constant when replacing an overflowing transcript with three rows. Its automatically hidden scrollbar can change the gutter by 17 points. This failed once and passed on the unchanged rerun. Stabilize scrollbar occupancy in that fixture while preserving its row-height and gap assertions; production passage behavior does not depend on the assertion.

# Validation

Synthetic tests cover sentence endings, decimal continuation, different speakers, overlapping turns, sessions, sources, manual protection, spacing, anchor continuity, constituent playback, navigation, and expansion. Parent review corrected draft isolation, whitespace composition, stale navigation indexes, and context-menu editing of a continuation. Menu actions now retain the canonical target from the opening mouse event.

The initial release suite passed 51 tests in five suites. After the menu fix, the unchanged release suite rerun passed all 52 tests in five suites following the existing scrollbar-width timing failure described above. The isolated final release build passed. Formatting and diff checks passed. The toolchain still warns about two missing Command Line Tools linker search paths; no deprecated API warning was encountered.

Before-and-after screenshots confirmed that the reported sequence of short continuation rows reads as one sentence while speaker changes remain separate. A real-app double-click expanded the passage and edited the clicked constituent; Escape cancelled without changing text. The final context-menu fix passed its synthetic event-routing test. A newly active recording in the installed app prevented reopening the final review bundle against the same library, so the final context-menu interaction was not manually exercised. The final bundle is ready separately at `tmp/Gday Meetings Diarization Review.app`; the active recording was left untouched.
