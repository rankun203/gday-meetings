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

Keep model identifiers, vectors, and raw scores out of the main review flow. A secondary preparation view names available providers and shows progress, missing audio, failed excerpts, and pause/resume controls. Empty states explain the next action. Samples without reliable ranges are unavailable for playback until usable evidence is found; never invent a timestamp. Confirm and Assign remain available without a playable excerpt.

Each example has expandable **Voice Details** for its audio source and one list of model representations. Show saved model identity and revision, extraction provenance when known, and matching eligibility. Unknown metadata must remain explicitly unknown. Do not display raw vectors or divide models by import age. An unconfirmed person link must not be presented as a fresh model suggestion.

When reviewing a sample without an excerpt, resolve its source from saved speaker and transcript metadata before asking the user to search manually. Recovering playback metadata does not revoke a confirmed identity or invalidate compatible saved representations. **Open Recording** scrolls to and selects the saved speaker passage without starting playback. If no reliable passage exists, explain the missing link rather than guessing from a person's name.

## Evidence and compatibility

The durable identity is a voice sample with review provenance and available recording/source references. An exact range enables playback and new extraction, but is not required to confirm the sample. Each sample can have representations from several embedding spaces. A person has derived profiles per compatible space, built from valid compatible representations of active confirmed samples, regardless of import origin or current audio availability.

Embedding compatibility includes model identity, revision, preprocessing compatibility, dimensions, and normalization. A provider configuration is provenance, not an embedding-space key. Providers using the same extraction contract share representations. A model change that breaks compatibility creates new representations without discarding names or human decisions. Vectors from different spaces are never averaged or compared directly.

Automatic suggestions do not train profiles. Existing person links and legacy vectors do not establish user confirmation. Migration preserves them as reviewable evidence. Manual decisions must override matching after saving, reopening, relabeling, and preparing another model. Exact reviewed ranges remain authoritative when provider speaker boundaries change; ambiguous remapping requires review.

## Preparation and discovery

Preparation first reuses compatible vectors, then extracts a bounded set of reviewed audio excerpts with the selected supported model. It does not retranscribe meetings or overwrite their transcript. Missing audio, unsuitable ranges, and extraction failures are reported individually. Jobs persist progress, pause safely, resume after interruption, and avoid duplicate representations.

Discovery inventories saved speaker evidence, proposes conservative groups from compatible embeddings, and can extract suitable saved ranges locally. It must not silently turn old automatic names into enrollment truth. Separate discovery from preparing already confirmed voices so adding a provider does not require scanning every recording.

Current local live and recorded labeling share the Community-1 voice extractor. The repository’s RunPod worker uses the same upstream embedding weights as the [Community-1 Core ML conversion](https://huggingface.co/FluidInference/speaker-diarization-coreml). Known RunPod provenance maps to that model space after dimension, finite-value, and normalization checks. Explicit provider model metadata takes precedence; different models and incomplete declared contracts are not silently combined. The worker pins its upstream revision and returns a typed, normalized embedding contract. Existing raw output from this worker remains usable.

RunPod remains unavailable for sample-by-sample preparation because the app has no extraction adapter for that operation. Its existing vectors can participate in matching; saved boundaries can also provide source ranges for local extraction. No remote upload is initiated by opening People or adding a provider. A future remote preparation flow must describe selected audio and destination before submission.

Tasks presents running work before history. Standalone Speaker Labeling has a durable task lifecycle, and voice preparation/discovery jobs appear with their saved progress and recovery controls. The voice job record remains authoritative; task presentation must not create a second independent job state.

Speaker Labeling history is available beside Label Speakers. Its tooltip summarizes the latest recorded run. The accessible history popover combines task records with older saved analyses, linking records only by an exact result identifier. A saved analysis without application evidence does not claim that its labels were applied. Opening history does not start processing.

## Incremental storage

Authoritative voice evidence remains portable files. Replace the single `voice-library.json` document with separate records under `voice-library/`: example metadata in `examples/<UUID>.json`, active and historical model representations in `representations/<UUID>.json`, and each preparation job in `jobs/<UUID>.json`. Speaker decisions, Undo entries, and deleted-person records have separate files. Updating job progress must not read, encode, or rewrite voice vectors; changing a review decision must not rewrite unchanged representations.

An update stages only affected records in a redo transaction before publishing them. A versioned state record tracks the committed revision; stale writers must fail rather than overwrite a newer correction. Interrupted committed updates replay before reads expose their state. Review decisions and their Undo records commit together. Meeting transcript projections remain separate derived writes: report projection failures and retry from the durable decision instead of reporting that the decision was lost.

Indexes are disposable and can be rebuilt from these files. Opening the library or displaying job progress must not hydrate every vector. Read representations when matching or preparing evidence, and selected representations when expanding their details. Explicit grouping can read the representations of its candidate examples. Incremental persistence alone does not establish paged UI reads: the current integration retains lightweight metadata in memory and must document its full metadata scans separately.

The app must not silently convert the old monolithic file. A separate, explicit migration operation verifies its source, stages new records, validates decoded values and identifiers, and publishes only a complete result. Preserve a verified original for rollback, reject conflicting destinations, and leave unrelated files unchanged. The new app provides an actionable refusal when legacy storage remains. Normal app reads must never fall back to stale predecessor data.

For an existing development library, use the data folder shown in Settings > Data. From the repository root, first inspect the conversion with `uv run --no-project scripts/migrate_voice_library.py "/path/to/data-folder"`. Quit Gday Meetings before applying it with `uv run --no-project scripts/migrate_voice_library.py "/path/to/data-folder" --apply --app-stopped`, then launch the new app. The command keeps `voice-library.json.pre-sharded-backup`; it does not modify recordings or People files. It also supports libraries whose voice samples are still stored only in People files. Do not run an older app against the converted library.

## Matching and evaluation

Treat unknown voices as expected. Match only compatible reviewed profiles, honor corrections, and withdraw unsupported automatic live assignments. Preserve a distinction between automatic association and user confirmation. Each embedding space requires its own evaluated decision policy; cosine similarity is not an identity probability.

Validation must include unrelated video speakers, one-person galleries, mixed microphone/system conditions, short and overlapping speech, and held-out recordings. User confirmations improve the evidence library without retraining the base neural model. Threshold changes alone do not establish improved accuracy. Do not automatically tune thresholds on the same examples used for enrollment and claim independent validation.

## Implementation and validation

Implement durable evidence and decisions, playable review and corrections, and supported local preparation/discovery with resumable work. Use synthetic fixtures and temporary libraries for persistence, undo, compatibility, grouping, extraction failure, and playback tests. Review narrow and wide layouts, light and dark appearances, keyboard access, unavailable audio, and job recovery in isolated Preview. Run the Swift release build and inspect the macOS CI matrix after pushing.

Record exact delivered behavior, validation limits, compatibility bridges, and any remaining follow-up in the implementation worklog. Recognition accuracy and remote extraction support must not be implied by UI or unit-test success.

Implementation and validation results are recorded in the [worklog](../worklogs/2026-10-03-people-voice-library.md). Automatic identity assignment remains deferred until held-out evaluation supports a calibrated policy for each embedding space.
