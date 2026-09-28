---
title: Show a completed provider transcript
date: 2026-09-28
status: validating
scope: swift-transcript-presentation
---

# Problem

After live transcription is replaced by a provider result, the transcript viewport could retain the previous version’s scroll position. The user reported that the meeting did not show the newly completed transcript automatically.

# Implemented solution

Provider completion already publishes the new transcript and source metadata, while preserving the prior version. Native transcript presentation now includes transcript source identity in its source-change detection. A new version in the same meeting settles the viewport once at the shared playback position, or at the top when that meeting is not playing. It clears the previous version’s temporary manual-scroll suppression. Changes to source metadata also refresh history and displayed rows.

# Reasoning

Meeting identity is insufficient when live, provider, and restored versions have different lengths. A source change is a document replacement; it should not inherit an out-of-range viewport from the previous document. Playback remains driven by the shared clock, without completion actions calling playback controls.

# Validation

Added a native regression replacing a deep 2,000-row document with a three-row version in the same meeting. Added a store regression checking that provider completion selects its source, preserves live history, and leaves another meeting unchanged. All 25 focused tests across NativeTranscriptTests, ProviderRoutingTests, and MarkdownSelectionSourceMapTests passed (/tmp/gday-transcript-source-tests.log). Visual verification remains with the parent agent.

# Technical debt

The store path already replaced the selected transcript correctly. This patch addresses a confirmed viewport-identity gap; reproducing the exact reported stale-live state remains part of final visual verification.
