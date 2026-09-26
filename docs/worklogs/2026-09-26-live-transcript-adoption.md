---
title: Use finalized live text as the meeting transcript
date: 2026-09-26
status: implemented
scope: swift-app-transcript-workflow
---

## Problem

Stopping a recording left useful live text in a separate draft that needed manual adoption. Live source names appeared as speakers. A saved recording's transcription action could only use the global default provider.

## Implemented solution

After live finalization, Stop adopts finalized text into an empty meeting transcript. The independent checkpoint retains source tracks, word data, and coverage gaps. Existing transcript edits, speaker assignments, and pending requests prevent automatic replacement. Explicit recovery preserves the previous transcript revision before replacing it. Failed metadata writes retain the checkpoint and roll back the transcript.

Live and unlabeled batch results use timed text with an empty speaker label and no speaker identity. Actual provider speaker labels remain unchanged. Summary context and Markdown export omit empty speaker prefixes.

Manual transcription can choose a configured eligible provider for one operation without changing Defaults. Pending requests stay bound to their original provider and endpoint; a conflicting choice fails before uploading or submitting. Existing replacement-conflict and failed-job recovery behavior remains in place.

## Reasoning

The normal transcript already supports editing, search, summaries, and export. Adopting only into an empty transcript avoids overwriting work. Independent checkpoints and revisions preserve recovery paths while keeping source tracks distinct from people.

## Technical debt

Legacy live-only meetings are recovered at library load only when their transcript and speakers are empty and no request is pending. A default-false adoption marker saves atomically with the text, so clearing a previously adopted transcript does not restore it on the next launch. The UI retains a read-only fallback for recovery failures, without mutating data merely by rendering a view. Source-track metadata remains in the live checkpoint; the existing canonical transcript schema has no separate track field. A future schema extension can retain track provenance in all transcript providers without treating tracks as speakers.

## Validation

Offline tests cover synthetic Stop finalization, persistence, no fake speakers, edit conflicts, explicit revision recovery, empty/foreign/pending drafts, metadata-save failure, and manual provider selection without changing Defaults. All 261 tests in 54 suites passed, including legacy recovery and a subsequent deliberate clear. Formatting and lint passed. Preview confirmed live timed rows, settings outside the text viewport, retaining final text when live recognition is turned off, and editable text after Stop without a manual adoption action or fake speaker. Final packaging includes the persisted legacy marker and fallback guard. No capture, model download, or provider upload occurred.
