---
title: People voice library
date: 2026-10-03
updated: 2026-10-22
status: implemented
scope: swift-people-speaker-association
---

# People voice library

## Problem

People currently shows contact details and associated meetings, without the audio evidence behind voice matches. Removing an incorrect assignment does not teach the next recording about the correction. Voice samples lose their source ranges, automatic and manual assignments share presentation, and new embedding models cannot reliably reuse reviewed speech.

The existing People screen was inspected on October 3 before implementation. Its split layout has a person list, contact form, meeting list, and contextual chat. Keep that navigation and the persistent player; make voice review discoverable without replacing familiar meeting access.

## Experience

People provides **Review Library** for named and unnamed people. A permanent compact horizontal bar above the person list and detail shows people with new pending matches and unnamed people, with one Review Library action. Loading, empty, and error states keep this entry point visible. The bar is navigation and cannot be dismissed. **Review This Person** is scoped to the selected person; both labels omit ellipses. The chooser shows named people with playable candidates first, followed by unnamed proposed people. Each chooser row is one line: person name, sample count, the most recent pending meeting’s title in a quiet label, and a count of additional meetings. Both open the same sample list and detail panel. Person-level review controls show the actionable candidate count and are disabled when no playable candidates exist. An unnamed group offers **Name This Person…**. A person's review includes existing samples as listening references, labeled by confirmation state. Recording titles, dates, sources, timestamps, and review states provide context. Opening or selecting an excerpt starts playback and cancels the previous excerpt, including pending loads. Excerpts stop at their boundary. Recording continues to block playback.

The voice library owns one review snapshot for controls, the library bar, chooser rows, and dialog queues. It shares evidence reads. Decisions and in-app audio deletion or replacement invalidate immediately. Model representation updates coalesce and retain the last completed UI result while refreshing; job progress leaves the snapshot valid. Named and unnamed sections have disjoint visible excerpts; linked evidence remains available for group naming. Ineligible excerpts never become review questions. Explicit refresh rechecks external audio changes.

Review groups likely voices before they have names. Naming a group confirms the focused anchor sample and saves the other members as named associations awaiting confirmation. Creating a person and assigning the group completes in one action. Users can correct individual members. Group membership is a revisable inference, never evidence of a confirmed identity. Session rows retain their order and show naming or review progress until an explicit refresh. Recording titles lead the sample list so users can prioritize familiar meetings.

Keep sample rows to three lines: recording title; meeting date and time followed by the excerpt range and duration; status icon and text. Use semantic icon colors with text, preserving native selection styling. The detail shows transcript text from the sample's source and overlapping time ranges. Place the transcript below the identity question and playback controls. Highlight saved word timings when available; leave untimed text plain and omit timing implementation explanations. Show **Transcript unavailable.** when no source-aligned text exists. Review actions retain their position while saving.

**Not [Name]** rejects that identity for the selected evidence and removes its contribution to the profile. **Ignore Sample** excludes unsuitable speech from queues and profiles while retaining the recording. **Remove Assignment** clears attribution and suppresses automatic reassignment of the corrected evidence. Corrections and group changes support Undo and survive reopening and provider preparation. Rejections and exclusions also apply to regenerated examples with the same audio revision, source file, and exact ranges. General noise classification remains future work; ignoring a sample does not suppress other speech by embedding similarity.

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

Local recorded diarization and saved voice-example preparation share the Community-1 voice extractor. The repository’s RunPod worker uses the same upstream embedding weights as the [Community-1 Core ML conversion](https://huggingface.co/FluidInference/speaker-diarization-coreml). Known RunPod provenance maps to that model space after dimension, finite-value, and normalization checks. Explicit provider model metadata takes precedence; different models and incomplete declared contracts are not silently combined. The worker pins its upstream revision and returns a typed, normalized embedding contract. Existing raw output from this worker remains usable.

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

Transcript attribution and reference-sample review serve different purposes. A reference excerpt supplies evidence; its selected playback range does not bound the detected speaker's identity. A qualifying association applies to all supported passages of that detected speaker. Unresolved source-only passages remain unresolved. Discovery results from a separate scan must map unambiguously to the saved detected speaker before extending an attribution beyond the excerpt.

Recorded transcript matching uses confirmed reference profiles. The default automatic rule requires similarity of at least 0.80 and a lead of 0.08 over the next comparable person. A positive score with that lead over another comparable person can produce a tentative attribution below the automatic threshold. Tentative names show a question mark; accessible help distinguishes tentative, automatic and assigned identities. These defaults are provisional policies, not calibrated confidence estimates. Explicit provider settings remain authoritative. Review suggestions retain their independent 0.55 threshold.

Persist machine attribution separately from human confirmation, including its score, margin, tier and policy. Validate audio and policy before projecting it; saved-speaker evidence validates its diarization generation, while separate discovery validates configuration and current row coverage; preserve manual corrections and Undo. Automatic and tentative transcript names never enroll reference audio. Only explicitly confirmed suitable excerpts contribute to future matching. Tentative names stay outside meeting attendance and confirmed search metadata; speaker controls and exported or generated text identify them as tentative. A transcript correction changes speaker identity without approving every reference excerpt. Keep acoustic uncertainty separate from tentative person identity so a tentative name does not claim that an unresolved passage has a detected speaker.

Validation must include unrelated video speakers, one-person galleries, mixed microphone/system conditions, short and overlapping speech, and held-out recordings. User confirmations improve the evidence library without retraining the base neural model. Threshold changes alone do not establish improved accuracy. Do not automatically tune thresholds on the same examples used for enrollment and claim independent validation.

## Implementation and validation

Implement durable evidence and decisions, playable review and corrections, and supported local preparation/discovery with resumable work. Use synthetic fixtures and temporary libraries for persistence, undo, compatibility, grouping, extraction failure, and playback tests. Review narrow and wide layouts, light and dark appearances, keyboard access, unavailable audio, and job recovery in isolated Preview. Run the Swift release build and inspect the macOS CI matrix after pushing.

Record exact delivered behavior, validation limits, compatibility bridges, and any remaining follow-up in the implementation worklog. Recognition accuracy and remote extraction support must not be implied by UI or unit-test success.

Earlier implementation and validation results are recorded in the [original worklog](../worklogs/2026-10-03-people-voice-library.md). The [review and transcript attribution worklog](../worklogs/2026-10-21-review-responsiveness.md) records the current policy, exploratory evaluation and its limits. Broader held-out evaluation remains required before claiming calibrated identification accuracy.
