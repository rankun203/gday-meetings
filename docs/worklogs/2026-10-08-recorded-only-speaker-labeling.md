---
title: Move speaker labeling after recording
date: 2026-10-08
status: validated
scope: macos-recording-and-speaker-labeling
---

# Problem

Live speaker labeling competes with capture and live transcription. The previous release build remained slow during the user's recording test. The product now needs live text without speaker identity, followed by full saved-audio diarization and editable speaker labels.

# Implemented solution

The recording controller handles transcription alone. It no longer creates a diarization runtime, embedding worker, meeting identity clusterer, or People matcher. Recorded diarization uses the full saved audio after recording finishes, including when the live transcript is adopted without retranscription. Completion updates the existing transcript's speaker assignments through the managed labeling task.

The recording UI displays text without a speaker column or live processing switches. Settings controls live transcription; the transcript header contains only issue details and Follow Live. General settings place speaker labeling and People association only under After Recording. The local provider exposes Community-1 diarization without Nemotron configuration. The transcript text moves 112 points left when the speaker column is absent. Retired live-speaker settings and provider capabilities are removed; the recorded workflow defaults to the local Community-1 provider.

New automatic-diarization and provider-selection storage keys discard retired speaker settings; this prevents an old disabled remote selection from becoming an automatic upload. Current explicit None/off choices round-trip normally.

Recorded jobs retain review embeddings even when automatic People association is off. Users can associate an anonymous label with a person after labeling completes. Needs Review includes both unassigned voices and suggested matches. Saved review groups use the same speaker identity as the meeting; automatic discovery does not independently regroup those clusters. Source metadata remains stored for timing and playback; source placeholders do not appear as identified people.

# Reasoning

A complete saved-audio pass has the full recording available for segmentation, overlap handling, embeddings, and clustering. It removes speaker inference from the capture critical path and avoids coupling meeting identity to live channel capacity. Previously saved speaker labels and corrections must remain readable.

# Validation

Before editing, inspected the running app's General and Speaker Diarization settings. Both exposed live labeling and association alongside recorded labeling; the provider required Nemotron for its live option. The revised layout removes those live controls and keeps the existing recorded-labeling controls and naming flow. The combined suite passed 1,179 tests across 215 suites in 127.334 seconds. Coverage includes stop-to-diarization scheduling without retranscription, source-placeholder replacement, cluster review identity, naming/clearing/rejection and undo, local-only defaults, and exact capture PCM continuity. An updated transport test accounts for valid resampler tail packets while verifying audio coverage and actual gaps. The isolated Release build and signature validation passed. In the built preview, recording shows text directly beside timestamps with no speaker controls; saved speaker review shows the two labels with usable embeddings and hides the label without evidence. People → Needs Review includes an unassigned group with a playable excerpt and Assign action. Final presentation-only changes remove the Transcribe switch and hide the redundant filter label so Needs Review fits. Those two UI files receive an incremental Release validation; processing logic remains the version covered by the full suite.

Visual checks use synthetic audio and an isolated temporary library. They do not constitute a new long live-capture CPU measurement. The full existing recording/capture tests passed; the installed app and original meeting library were not replaced during validation. The build reports existing Command Line Tools linker search-path warnings, not deprecated API warnings.

# Technical debt

None introduced. Removed the live runtime, Nemotron registry, live embedding/People workers, evidence-journal consolidation route, retired settings, and dependent experiment runners. Shared transcript source metadata and physical voice-example spans remain because saved transcript alignment and review use them.
