---
title: People voice library
date: 2026-10-03
updated: 2026-10-24
status: active
scope: swift-people-speaker-association
---

# People voice library

The library is implemented; the selective-review refinements below are agreed design intent with unresolved implementation and evaluation work. They do not describe the behavior of every delivered build. The [five-system research comparison](2026-10-24-voice-recognition-library.md) provides external evidence and discussion questions.

## Problem

People currently shows contact details and associated meetings, without the audio evidence behind voice matches. Removing an incorrect assignment does not teach the next recording about the correction. Voice samples lose their source ranges, automatic and manual assignments share presentation, and new embedding models cannot reliably reuse reviewed speech.

The existing People screen was inspected on October 3 before implementation. Its split layout has a person list, contact form, meeting list, and contextual chat. Keep that navigation and the persistent player; make voice review discoverable without replacing familiar meeting access.

## Experience

Associations organize the library automatically; confirmation improves recognition when useful. The intended outcome is useful automatic transcripts, correction when needed, and selective voice-library review. Recognizing a familiar speaker must not require confirmation in every meeting. Review should prioritize ambiguous identities and useful new reference evidence rather than repeatedly requesting approval of redundant examples.

A person's Meetings list includes every meeting with a transcript line associated with that person, including tentative associations, plus explicit attendance assignments. Count each meeting once. Corrections update derived membership automatically; removing the last associated line removes the derived link while preserving explicit attendance. One click opens the meeting dialog while retaining the profile underneath; keyboard selection and Return remain available. This navigation rule does not promote machine associations into confirmed training evidence.

Named transcript badges use soft solid borders for strong or confirmed associations and dotted borders for tentative associations, without a visible question mark. Both support correction. Source-only badges have no border because they offer no identity action. Color identifies the person using a stable person ID, or the audio source and speaker index for an unidentified voice. Color generation is deterministic across meetings and launches, supports arbitrary identities without a fixed palette cycle, and uses readable light and dark variants. Person chips share their treatment across transcripts and People; source, tag and recording-context chips use distinct muted fill levels. Color alone never communicates identity or confidence.

People provides **Review Library** for named and unnamed people. A permanent compact horizontal bar above the person list and detail shows people with new pending matches and unnamed people, with one Review Library action. Loading, empty, and error states keep this entry point visible. The bar is navigation and cannot be dismissed. **Review This Person** is scoped to the selected person; both labels omit ellipses. The chooser shows named people with playable candidates first, followed by unnamed proposed people. Each chooser row is one line: person name, sample count, the most recent pending meeting’s title in a quiet label, and a count of additional meetings. Both open the same sample list and detail panel. Person-level review controls show the actionable candidate count and are disabled when no playable candidates exist. An unnamed group offers **Name This Person…**. A person's review includes existing samples as listening references, labeled by confirmation state. Recording titles, dates, sources, timestamps, and review states provide context. Opening or selecting an excerpt starts playback and cancels the previous excerpt, including pending loads. Excerpts stop at their boundary. Recording continues to block playback.

The voice library owns one review snapshot for controls, the library bar, chooser rows, and dialog queues. It shares evidence reads. Decisions and in-app audio deletion or replacement invalidate immediately. Model representation updates coalesce and retain the last completed UI result while refreshing; job progress leaves the snapshot valid. Named and unnamed sections have disjoint visible excerpts; linked evidence remains available for group naming. Ineligible excerpts never become review questions. Explicit refresh rechecks external audio changes.

Review groups likely voices before they have names. Naming supplies an identity anchor; reference selection should choose a clear, useful excerpt of that same voice under the safeguards below. Other group members remain revisable associations and become review questions only when their answers would be useful. Creating a person and assigning the group completes in one action. Users can correct individual members. Group membership is a revisable inference, never evidence of a confirmed identity. Session rows retain their order and show naming or review progress; subsequent questions follow the action-specific rules below. Recording titles lead the sample list so users can prioritize familiar meetings.

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

Recorded transcript matching uses confirmed reference profiles. The default automatic rule requires similarity of at least 0.80 and a lead of 0.08 over the next comparable person. A positive score with that lead over another comparable person can produce a tentative attribution below the automatic threshold. Tentative badges use a dotted border; accessible help distinguishes tentative, automatic and assigned identities. Summary prompts retain an explicit question-mark convention for tentative attribution. They explain that source-only labels identify audio sources rather than people, allow context-supported inference, and preserve uncertainty when identity is unclear. These defaults are provisional policies, not calibrated confidence estimates. Explicit provider settings remain authoritative. Review suggestions retain their independent 0.55 threshold.

Persist machine attribution separately from human confirmation, including its score, margin, tier and policy. Validate audio and policy before projecting it; saved-speaker evidence validates its diarization generation, while separate discovery validates configuration and current row coverage; preserve manual corrections and Undo. Automatic and tentative transcript names never enroll reference audio.

Explicitly confirmed excerpts and suitable excerpts selected from a manually identified recording speaker may contribute to future matching. A transcript assignment establishes identity for that detected speaker throughout the recording; it does not approve an arbitrary embedding. Background selection must validate supported exclusive speech, audio quality signals, compatible representations and the current manual assignment before enrolling useful evidence. A manual speaker assignment supplies identity confirmation for automatic reference selection. A qualifying selected embedding enters the person’s recognition library without a second approval. Reviewing individual examples in People remains optional and can improve recognition further. Keep selection provenance separate from explicit excerpt confirmation. Changing or removing the identity withdraws references derived from that assignment while preserving independent reviews. Poor or inconsistent audio retains its transcript identity without becoming recognition evidence. Ordinary speaker assignment has no passage-scope checkbox; preserve legacy passage correction restoration separately.

People meeting membership includes tentative transcript associations; this supersedes the earlier exclusion of tentative names from that navigation. Keep confirmed search evidence distinct from tentative identity. A transcript correction changes speaker identity without approving every reference excerpt. Keep acoustic uncertainty separate from tentative person identity so a tentative name does not claim that an unresolved passage has a detected speaker.

Summary generation includes all associated named speakers. Mark tentative transcript names with `?` and explain once in the prompt that this suffix denotes low-confidence speaker attribution. The summarizing model can then account for uncertainty without losing named-speaker context. The prompt's participant context and transcript labels must agree; this does not establish verified attendance or voice enrollment.

Validation must include unrelated video speakers, one-person galleries, mixed microphone/system conditions, short and overlapping speech, and held-out recordings. User confirmations improve the evidence library without retraining the base neural model. Threshold changes alone do not establish improved accuracy. Do not automatically tune thresholds on the same examples used for enrollment and claim independent validation.

## Implementation and validation

### Selective review and reference admission

**User intention:** minimize the number of samples a person must review while producing the best recognition results. An unreviewed excerpt is not automatically unfinished work. Same-meeting samples should be reviewed only when they add useful evidence or resolve a real identity conflict. This supersedes the proposal to freeze every session into a batch that cannot offer replacements.

| Action | Intended result |
| --- | --- |
| Confirm | Save the decision; retire equivalent questions. Offer a materially different useful candidate or unresolved conflict when one remains. Do not silently replace the confirmed item with a redundant excerpt. |
| Ignore Sample | Persist exclusion of that excerpt and offer another suitable sample for the current review opportunity, if available. Failure to find or prepare an alternative does not undo exclusion. |
| Try Another Sample | Offer a clear alternative for the intended voice without rejecting its identity or automatically excluding the previous excerpt. Avoid cycling through already presented alternatives. |
| Skip | Leave the identity undecided and advance through useful questions; do not generate replacements solely because of Skip. |
| Name or assign an existing person | Save the identity at the stated scope; assess a clear sample from that voice for useful recognition evidence. A recognition miss followed by a correction is a strong usefulness signal. |
| Create a person | Create the person and association together. Enroll a suitable clear sample of the identified voice as the initial confirmed reference when safe; retain an incomplete recognition state if suitable evidence is unavailable. |

Apply these rules consistently to transcript assignment and People review. The clicked excerpt anchors which voice the user means, but need not be the best reference. A replacement must have reliable same-voice support within the authorized scope. A shared diarization label alone is insufficient when the label contains mixed speakers. If continuity is uncertain, request confirmation of one useful replacement rather than silently confirming it. Preserve explicit excerpt confirmation separately from a reference derived from a label assignment.

Separate three decisions: identity, reference admission, and the need for another human question. Evaluate admission against the active profile using suitability, redundancy, coverage of different recording conditions, and possible replacement of a weaker reference. High novelty alone can indicate noise or another person. Successful automatic recognition alone does not establish that a clearer reference has no value. Thresholds and scoring remain evaluation questions; no fixed sample quota establishes useful coverage.

An explicit correction that disagrees with existing references must remain saved. Profile disagreement can require review of a substituted excerpt, but must not erase the correction or permanently prevent learning a legitimate new voice condition. Exact confirmed evidence can remain durable even when it is unsuitable or unnecessary for the active profile.

Keep all stored evidence accessible through maintenance. Suppressing a redundant question must neither confirm it nor delete its provenance. Recompute suppression when its supporting reference is removed, reassigned, undone, or becomes incompatible. A rescan or model change must preserve durable human decisions and re-evaluate derived coverage. Reopening should retain decisions and avoid repeatedly asking equivalent questions. New information may create useful questions, with a reason; a refreshed total should not disguise redundant refill as progress.

During selection, show short progress beside the speaker name. Preserve completed results for unaffected speakers. Final status should distinguish evidence added, evidence already covered, review needed, unavailable audio, and preparation failure, with explanatory hover text. Do not claim measured recognition improvement merely because a sample was admitted. Cancellation, changed assignments, replaced audio, and stale background results must not publish an obsolete reference. Undo must restore the identity, derived reference contribution, and review opportunity coherently.

### Code review findings, October 24

These findings came from source inspection, not a fresh runtime validation. Test16 (`027db65-test16-3884e13c`) and the current uncommitted working tree differ. Selection refinements in the working tree must not be described as delivered Test16 behavior.

| Finding | Code ownership | Required resolution |
| --- | --- | --- |
| Test16 bounds visible candidates but lets the next unreviewed turn replace a confirmed one; the open session appends arrivals. | `VoiceTurnReviewSelection`, `VoiceMatchReviewSession.refreshQueue` | Select useful questions against confirmed coverage, with action-specific continuation. A per-pass limit does not bound cumulative user effort. |
| Current reference admission rejects a sample below the existing person's suggestion threshold. A genuine correction can therefore be blocked by the recognition gap it exposes. | `VoiceReferenceSelection.rejection` in `VoiceLibraryPreparation.swift` | Separate explicit identity evidence from automatic consistency checks; handle conflicting replacement samples explicitly. |
| Reference support checks use transcript coverage and uncertainty, but cannot prove that another excerpt of a mixed label contains the anchored voice. | `prepareReference`, `supportedRange`, `isSupported` | Validate continuity before transferring confirmation; preserve the manual assignment if reference enrollment needs review. |
| Newer working-tree review selection treats a strong automatic match as covered. A clearer replacement can still improve the profile. | `VoiceReviewSelection.evaluate` | Assess marginal profile contribution separately from match confidence. |
| Newer session logic holds additional candidates outside the initial batch. Ignore excludes evidence without guaranteeing an alternative; Try Another uses a separate path. | `PersonMatchReviewView`, `VoiceMatchReviewSession`, `prepareAlternativeSample` | Unify continuation semantics while preserving each action's distinct durable decision. |
| Reference preparation accepts the first admissible candidate in a bounded search, with at most three audio attempts. Profile selection emphasizes diversity. | `prepareReference`, `VoiceProfileSelection` | Compare a bounded shortlist for clarity and contribution; avoid calling the first passing candidate the globally best sample. |
| People naming confirms the current anchor, while meeting assignment schedules reference selection. | `nameVoiceGroupResult`, `assignSpeaker` | Share admission policy and provenance without expanding the scope of a human confirmation. |

### Evaluation required for these refinements

Use synthetic regression fixtures for redundant turns, mixed labels, no alternative, ignored alternatives, novel but poor audio, clearer replacements, new people, conflicting identities, unavailable audio, Undo, retries, restart, model changes, and assignment changes during extraction. Test that suppression can be reversed without losing decisions and that separate people never merge through a chain of weak similarities.

Compare policies on held-out meetings with compatible models. Measure listening time and questions per person alongside false identity assignments, missed known speakers, profile contamination, and useful condition coverage. Compare quality-only selection, diversity-only selection, coverage plus quality, and correction-prioritized selection against the current baseline. Include unknown people and low-quality recordings. Split by meeting so adjacent excerpts cannot leak between enrollment and evaluation. Report results before choosing thresholds or claiming better accuracy.

**Technical debt:** current admission thresholds, bounded first-success selection, and differing naming paths remain unresolved compromises. Their consequences are missed useful corrections, potentially redundant work, and inconsistent enrollment behavior. Resolve through the shared policy and evaluation above; this documentation update adds no schema or runtime workaround.

Implement durable evidence and decisions, playable review and corrections, and supported local preparation/discovery with resumable work. Use synthetic fixtures and temporary libraries for persistence, undo, compatibility, grouping, extraction failure, and playback tests. Review narrow and wide layouts, light and dark appearances, keyboard access, unavailable audio, and job recovery in isolated Preview. Run the Swift release build and inspect the macOS CI matrix after pushing.

Record exact delivered behavior, validation limits, compatibility bridges, and any remaining follow-up in the implementation worklog. Recognition accuracy and remote extraction support must not be implied by UI or unit-test success.

Earlier implementation and validation results are recorded in the [original worklog](../worklogs/2026-10-03-people-voice-library.md). The [review and transcript attribution worklog](../worklogs/2026-10-21-review-responsiveness.md) records the current policy, exploratory evaluation and its limits. Broader held-out evaluation remains required before claiming calibrated identification accuracy.
