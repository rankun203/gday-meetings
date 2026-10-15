---
title: Live transcription and recorded speaker diarization
date: 2026-10-14
status: active
scope: macos-transcription-and-diarization-design
---

# Live transcription and recorded speaker diarization

The macOS app transcribes audio during recording and performs speaker diarization on saved audio after recording. It has no active live diarization provider. This document replaces the retired live-speaker design; its filename remains unchanged to preserve existing links.

## Current workflow

| Stage | Behavior |
| --- | --- |
| Recording | Capture microphone and system audio, save their source timelines, and optionally display live transcription through Apple SpeechAnalyzer. |
| After recording | Retain the live transcript or run the selected recorded transcription provider, according to the recording settings. |
| Speaker Diarization | Process saved audio with the local Community-1 adapter, or request diarization with supported remote transcription. |
| Speaker Association | Optionally match compatible voice embeddings against reviewed samples in the People Library. Manual assignments take precedence. |

Transcription produces text. Diarization identifies acoustic speakers within an analysis. Speaker Association connects those identities to People. A microphone or system-audio source is not a speaker identity, and an anonymous speaker label does not establish a person's name.

## Transcript interface

Live and saved transcripts use the shared native transcript table. Live rows show timestamps, source icons, and text. Microphone and system-audio icons use distinct colors and accessible names. Provisional text remains visibly distinct from finalized text.

Editing or scrolling away pauses automatic following. The icon-only Follow Live button appears at the bottom-right of the transcript while following is paused and disappears when following resumes. Manual text edits remain separate from incoming recognition updates.

Saved transcripts expose speaker review and person assignment. **Transcripts** selects saved text versions; **Diarizations** opens speaker-analysis history and the **Diarize** action. Preserve prior text and manual decisions when changing analysis results. See the [diarization protocol](../protocols/diarization.md) for compatibility and restoration rules.

## Settings and models

**General → Recording** controls live transcription. **After Recording** controls recorded transcription, **Automatically Diarize**, and **Automatically Associate People**. Speaker Association is app behavior, not a separately selected provider capability.

The local **Speaker Diarization** provider exposes Community-1 model installation and readiness. It uses pinned Core ML assets through FluidAudio for saved-audio analysis and voice extraction. Apple speech assets are managed through the system speech APIs. Downloading or verifying a model does not enable a disabled processing preference.

Opening provider settings or People review must not upload recordings or start analysis. Remote transcription follows the configured provider's explicit submission and data-destination rules.

## Timing and provider boundaries

Preserve each source track's timeline and capture gaps. Provider output must identify its source and the timing precision actually supplied. Coarse text timing is not word-level alignment; source-only or unresolved attribution must not be presented as a confirmed speaker.

The provider-neutral contract and diarization-driven passage changes under development do not introduce an active live diarization implementation. Future capability definitions must remain distinct from available adapters and tested runtime behavior. See the [transcription](../protocols/transcription.md) and [diarization](../protocols/diarization.md) contracts for the relevant boundaries.

## Validation and historical evidence

Use synthetic fixtures for persistence, editing, timeline, and provider-contract tests. Real audio review is required to assess transcription accuracy, speaker boundaries, overlap, and person matching. Model installation and a successful build do not establish those quality measures.

The [recorded-only speaker diarization worklog](../worklogs/2026-10-08-recorded-only-speaker-labeling.md) records removal of the live speaker runtime, model registry, and evidence-consolidation path. Earlier worklogs and experiment reports retain historical measurements; they do not describe current app capabilities.
