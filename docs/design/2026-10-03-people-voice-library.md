---
title: People voice library
date: 2026-10-03
status: implemented
scope: swift-people-speaker-association
---

# People voice library

## Problem

People currently shows contact details and associated meetings, without the audio evidence behind voice matches. Removing an incorrect assignment does not teach the next recording about the correction. Voice samples lose their source ranges, automatic and manual assignments share presentation, and new embedding models cannot reliably reuse reviewed speech.

The existing People screen was inspected on October 3 before implementation. Its split layout has a person list, contact form, meeting list, and contextual chat. Keep that navigation and the persistent player; make voice review discoverable without replacing familiar meeting access.

## Experience

People gains **Review Voices**. A person's detail includes playable voice examples. Review presents named, unnamed, and suggested evidence with recording, date, source, timestamp, and review state. Short excerpts play through the existing transport and stop at their boundary. Opening the recording seeks to the same timestamp. Recording continues to block playback.

Review groups likely voices before they have names. Naming explicitly selected examples confirms those examples; unreviewed group members remain suggestions. Users can assign examples to an existing person, create a person, combine voice groups, and separate selected examples. Combining voice groups does not merge contact records. Group membership is a revisable inference, never evidence of a confirmed identity.

**Not [Name]** rejects that identity for the selected evidence and removes its contribution to the profile. **Don't Use for Voice Recognition** excludes unsuitable speech without asserting a different identity. **Remove Assignment** clears attribution and suppresses automatic reassignment of the corrected evidence. Corrections and group changes support Undo and survive reopening and provider preparation. Rejected evidence also suppresses sufficiently similar suggestions in the same embedding space; it does not change other confirmed assignments or ban a person from an audio source.

Keep model identifiers, vectors, and raw scores out of the main review flow. A secondary preparation view names available providers and shows progress, missing audio, failed excerpts, and pause/resume controls. Empty states explain the next action. Legacy examples without reliable ranges are labeled unavailable for playback until usable evidence is found; never invent a timestamp.

## Evidence and compatibility

The durable identity is a voice example referencing a meeting, audio asset/source, and exact range, with review provenance. Each example can have representations from several embedding spaces. A person has derived profiles per compatible space, built only from active confirmed examples.

Embedding compatibility includes model identity, revision, preprocessing compatibility, dimensions, and normalization. A provider configuration is provenance, not an embedding-space key. Providers using the same extraction contract share representations. A model change that breaks compatibility creates new representations without discarding names or human decisions. Vectors from different spaces are never averaged or compared directly.

Automatic suggestions do not train profiles. Existing person links and legacy vectors do not establish user confirmation. Migration preserves them as reviewable evidence. Manual decisions must override matching after saving, reopening, relabeling, and preparing another model. Exact reviewed ranges remain authoritative when provider speaker boundaries change; ambiguous remapping requires review.

## Preparation and discovery

Preparation first reuses compatible vectors, then extracts a bounded set of reviewed audio excerpts with the selected supported model. It does not retranscribe meetings or overwrite their transcript. Missing audio, unsuitable ranges, and extraction failures are reported individually. Jobs persist progress, pause safely, resume after interruption, and avoid duplicate representations.

Discovery inventories saved speaker evidence, proposes conservative groups from compatible embeddings, and can extract suitable saved ranges locally. It must not silently turn old automatic names into enrollment truth. Separate discovery from preparing already confirmed voices so adding a provider does not require scanning every recording.

Current local live and recorded labeling share the Community-1 voice extractor. The existing RunPod adapter returns vectors without an extraction compatibility contract. It remains unavailable for reusable voice extraction until it advertises a supported contract; RunPod-derived boundaries can still provide source ranges for local extraction. No remote upload is initiated by opening People or adding a provider. A future remote preparation flow must describe selected audio and destination before submission.

## Matching and evaluation

Treat unknown voices as expected. Match only compatible reviewed profiles, honor corrections, and withdraw unsupported automatic live assignments. Preserve a distinction between automatic association and user confirmation. Each embedding space requires its own evaluated decision policy; cosine similarity is not an identity probability.

Validation must include unrelated video speakers, one-person galleries, mixed microphone/system conditions, short and overlapping speech, and held-out recordings. User confirmations improve the evidence library without retraining the base neural model. Threshold changes alone do not establish improved accuracy. Do not automatically tune thresholds on the same examples used for enrollment and claim independent validation.

## Implementation and validation

Implement durable evidence and decisions, playable review and corrections, and supported local preparation/discovery with resumable work. Use synthetic fixtures and temporary libraries for persistence, undo, compatibility, grouping, extraction failure, and playback tests. Review narrow and wide layouts, light and dark appearances, keyboard access, unavailable audio, and job recovery in isolated Preview. Run the Swift release build and inspect the macOS CI matrix after pushing.

Record exact delivered behavior, validation limits, compatibility bridges, and any remaining follow-up in the implementation worklog. Recognition accuracy and remote extraction support must not be implied by UI or unit-test success.

Implementation and validation results are recorded in the [worklog](../worklogs/2026-10-03-people-voice-library.md). Automatic identity assignment remains deferred until held-out evaluation supports a calibrated policy for each embedding space.
