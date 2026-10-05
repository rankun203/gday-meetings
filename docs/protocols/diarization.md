---
title: Diarization protocol
date: 2026-10-01
status: active
scope: capability-contract
---

# Diarization

## Purpose

Diarization assigns speaker labels to audio time ranges. The UI calls this capability **Speaker Labeling**. A label identifies a voice within the result; it does not establish a person's identity.

## Contract

Input contains identified audio tracks, their timeline offsets, and optional minimum and maximum speaker counts. An adapter may accept existing timed text to associate labels with transcript segments. Validate that speaker-count bounds are positive and ordered.

Output associates each track with speaker ranges. Each range has a start time, end time, and speaker identifier. Speaker identifiers are scoped to their track and job unless the provider explicitly supplies a broader identity contract. Word or segment assignments may accompany the ranges. Voice embeddings are optional sensitive output, not names or verified identities.

Follow the [shared provider rules](README.md). Audio goes to the chosen provider and any disclosed transfer service. Enabling this capability does not grant ongoing access to the library.

## Operations and results

| Operation | Result |
| --- | --- |
| Submit audio | A job identifier, or a combined transcription job identifier. |
| Inspect progress | Queued, running, completed, failed, or canceled. |
| Retrieve labels | Speaker ranges or speaker assignments tied to the input tracks. |
| Cancel, when supported | Confirmed cancellation or an explanation that work may continue. |

An implementation can combine diarization with [transcription](transcription.md) to reuse the same upload. It must request labels only when enabled. A transcription-only result must not be described as completed speaker labeling.

## RunPod adapter

The audio worker accepts `diarize`, `min_speakers`, and `max_speakers` in the transcription input. Returned segments can contain `speaker`; tracks can contain `speaker_embeddings`. RunPod submission, polling, authentication, and cancellation use the [transcription transport](transcription.md).

The worker needs configured Hugging Face model access for diarization. The current worker can skip diarization when that access is missing. A successful health check cannot establish that these models are available. Missing labels must not be presented as verified speaker identities or fabricated by the client.

The server `DiarizationProvider` extends `TranscriptionProvider`; `diarize` selects combined processing. The local Community-1 adapter has an independent saved-audio job and does not require transcription. Native streaming labels use a separate Live Diarization contract, with track/session-scoped identities and independent audio subscriptions. See [Live Transcription and Diarization](../design/live-transcription-research.md) for the shared timing, manual-override, and model-management design.

Standalone diarization without transcription is not implemented by the RunPod adapter.

## Local adapters

Community-1 runs an independent saved-audio job under **Speaker Labeling**. It prepares each local source, clusters the complete source, and saves a private speaker-range result. Applying the result preserves text, transcription provenance, and existing person assignments. Labeling provenance is stored separately. Untimed phrases receive a label only when one source has a clear dominant speaker; overlapping or ambiguous phrases retain their existing attribution. Cancellation leaves the active transcript unchanged.

**Transcripts** lists distinct text versions. **Labelings** contains labeling runs and **Restore Labels** for snapshots with the same transcription source, words, timing, tracks, and sessions as the current transcript. Restoring labels preserves current manual person assignments. Full snapshots remain available for text restoration; older combined snapshots are separated only when their original text source can be identified unambiguously. Starting a new transcription clears the previous standalone labeling provenance.

Nemotron supplies **Live Speaker Labeling** through a separate capability. The app supports seven pinned presets through the same Swift adapter, with independent state and identity generations per source. Each session has eight output slots. A restart creates new identities and records a coverage gap. The app's versioned activity filter uses 0.55/0.45 hysteresis with 50 ms onset and 100 ms release runs; the earlier benchmark used a raw 0.5 threshold. Its DER and first-output measurements therefore do not validate this app policy.

Both adapters acquire verified local models from the shared manager. A copied folder remains unavailable until pinned file verification and runtime preparation succeed. Model leases prevent removal during use; independent jobs receive separate Core ML instances. Installation and synthetic runtime checks do not establish combined transcription/labeling/recognition capacity, energy use, device placement, or representative name-matching accuracy. Final integrated validation is ongoing.

## Person assignments in the Swift app

Live and saved transcripts share the native table and person picker. The saved Transcript tab also has a Speakers disclosure below the transcript. A meeting can have multiple tags independently of speaker assignments. Assign or reassign a speaker to an existing or new person, or remove an assignment. Person links contribute to meeting context. Automatic matching never adds an enrollment sample by itself.

Every voice embedding has a model type: model identifier, weights revision, preprocessing compatibility version, dimension, and normalization. Compare and aggregate only embeddings with exactly the same type. A person can have multiple samples from multiple models; each type has its own profile. Endpoint equality or equal vector dimensions never establishes compatibility.

The current RunPod worker does not report an embedding model/version. Its existing untyped vectors remain preserved as unknown legacy data and are excluded from automatic matching until their generating model is established. Do not infer a type from the configured endpoint. Locally extracted Community-1 voice vectors carry the pinned model and preprocessing type. The initial local matcher uses a conservative 0.85 cosine threshold and 0.08 candidate margin; these are engineering defaults, not calibrated probabilities. Live naming also requires repeated supporting speech windows. At most one batch speaker per track is matched to each person. Manual attribution takes precedence.

Rust imports preserve labels, tracks, existing person links, and available attributed samples. An existing person link remains assigned even without a usable voice sample; it does not establish compatibility for future automatic recognition. Imported vectors resolve to an unknown legacy type and do not train a known-type profile. Old Swift display labels migrate without inferred person links. Library format version 2 retains a backup before upgrading version 1.

Voice samples stay in the local library. Text exports omit vectors; website archives omit both typed and legacy embeddings and person voice samples. Removing or reassigning a speaker removes its previous enrollment contribution. Live enrollment requires an explicit person assignment plus suitable single-speaker audio and a valid typed vector; assigning an unresolved source placeholder alone cannot create a voice sample.
