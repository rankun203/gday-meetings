---
title: Transcription protocol
date: 2026-09-26
status: active
scope: capability-contract
---

# Transcription

## Purpose

Convert selected recording tracks into timed text. Recording and saving audio remain independent of this capability.

## Contract

The app requires an explicit language for every transcription provider. Automatic language detection is not supported in the app; it remains a future option. Empty or `auto` values must be corrected before uploading audio. Existing submitted jobs can still be polled.

Input identifies the meeting, tracks, language, and whether [Speaker Labeling](diarization.md) are requested. Each track has a stable name, source type, audio location, and timeline offset. The adapter must explain every destination that receives audio.

Language belongs to the meeting's recording configuration. Choose it when creating the meeting and edit it in that meeting later. New meetings use **Settings → General → Transcription Language**, initially English (`en`). Changing the default does not change existing meetings. A transcription attempt snapshots the meeting's language and the resolved provider code before uploading audio; resuming preserves both snapshots. Changing the meeting language affects future attempts, not a queued or running job. Providers may report supported languages, but do not own the chosen meeting language.

The current worker recognizes Chinese as `zh`. Its `zh-cn` and `zh-tw` inputs select Simplified or Traditional output: both use `zh` for recognition, then OpenCC converts segment and word text. Plain `zh` leaves the recognized text unchanged. `zh-Hans` and `zh-Hant` do not select conversion in the current handler. See [worker language handling](../../apps/worker-audio-extraction/src/audio_extraction/handler.py).

The app owns an offline standard language list, independent of provider selection. Each adapter maps a meeting choice to an explicitly supported provider code before upload. The Gday Meetings website reports its supported codes, and the Swift app ships the RunPod worker's list. Chinese Simplified and Traditional remain distinct; neither is silently mapped to bare `zh`. See [standard language choices](../design/languages.md). The worker always aligns recognized text, so its catalog includes only languages supported by both recognition and its installed alignment metadata. Discovery does not establish deployed model availability or accuracy.

The result contains text segments with start and end times, track identity, language, and model information when available. Word timing and speaker assignments are optional. Track-relative timestamps are restored to the meeting timeline when results are combined.

Follow the [shared provider rules](README.md). Do not replace source recordings. A usable empty transcript is distinct from malformed output. Preserve edited text when applying a result would overwrite a newer version.

## Operations and results

| Operation | Result |
| --- | --- |
| Check connection | Authenticated service metadata without audio submission. |
| Submit selected audio | Job identifier and initial state. |
| Inspect progress | Queued, running, completed, failed, canceled, or expired. |
| Retrieve transcript | Validated timed text for the submitted tracks. |
| Cancel, when supported | Confirmed cancellation or notice that processing may continue. |

Keep the accepted job identifier so polling failures do not cause another paid submission. An ambiguous submission response requires checking the provider before repeating work. Retry and retention guarantees depend on the transport.

## Discover supported languages

Provider discovery reports supported request codes for adapter validation. The app's standard choices remain available when a provider has no catalog; that absence blocks new transcription, not recording or language selection. Do not substitute another provider's support list. RunPod uses the worker list shipped with the app (see [RunPod built-in list](#runpod-built-in-list)). Existing unknown imported codes stay visible and require an exact supported code; there is no free-text language entry or automatic detection (`auto`).

The metadata operation sends no audio, transcript, or meeting identifier. It reports recognition and alignment support without initializing inference or downloading model weights:

```json
{
  "protocolVersion": 1,
  "transcription": {
    "languages": [
      { "code": "en", "name": "English" },
      { "code": "zh-cn", "name": "Chinese (Simplified)" }
    ]
  }
}
```

This is an example response, not a fixed list. Version 1 requires a nonempty array of at most 256 entries, unique codes up to 40 characters, and nonempty names up to 120 characters. Codes use two or three lowercase letters followed by optional hyphen-separated lowercase letter or digit groups of two to eight characters. Reject duplicate codes, `auto`, malformed values, and unsupported protocol versions.

| Provider transport | Metadata operation | Result |
| --- | --- | --- |
| RunPod | `POST /runsync` with `{"input":{"operation":"capabilities"}}` and Bearer authentication. The Swift app does not send it. | RunPod job envelope; metadata is in `output` when `status` is `COMPLETED`. |
| Local audio worker | Authenticated `GET /capabilities` | Metadata object, or HTTP 503 when unavailable. |
| Gday Meetings website | Authenticated `GET /api/platform/capabilities` | Existing platform fields plus `protocolVersion: 1`, `transcriptionLanguages`, and `transcriptionLanguagesError`. |

The website obtains its list from its configured worker. It returns `transcriptionLanguages: null` with an explanatory error if no worker is configured or discovery fails; other platform capabilities remain available. It must not substitute a built-in list.

RunPod metadata can queue while a worker starts. A client that uses it polls the returned metadata job ID instead of submitting another job. Discovery is audio-free, but RunPod can still charge for worker execution. The website's discovery request is free. The desktop client never discovers languages automatically: it saves the website's list with its fetch time and asks again only when the person chooses **Load Languages** in the provider panel, or when **Transcribe** finds no saved list. Showing a picker reads only the app-owned standard list. The website bounds discovery to 60 seconds and 30 polling attempts, caches success for five minutes and failure for five seconds, and shares an in-flight lookup. Cache identity includes endpoint, authentication, and worker kind. Configuration changes bypass the previous cache. The desktop client keys its saved list by provider, kind, endpoint, and model. It excludes credentials, because a new key reaches the same worker, and it keeps the list until **Load Languages** replaces it. A saved list can be outdated: submission uses it to reject unsupported languages, and a failed discovery can be retried with **Load Languages**.

Distinguish these states:

- **Unknown:** the provider has not returned a valid list. Keep the standard meeting choices available; offer **Load Languages** in the provider panel.
- **Unavailable:** the request failed or the provider lacks metadata support. Keep the saved meeting language, explain the problem, and offer another check.
- **Unsupported:** a valid current list excludes the saved code. Preserve the meeting setting, but require a supported choice before submitting a new transcription.

A pending transcription retains its language snapshot and can resume polling without changing it. Changing the selected provider must not rewrite existing meeting languages. Recording remains available even when discovery fails.

The worker builds its list from the installed WhisperX language names intersected with its built-in alignment-model maps. English-only `.en` models report English only. When Chinese is supported, it also reports `zh-cn` and `zh-tw`, which use the worker's existing script conversion. This reports implemented language routes, not proof that weights are cached or that accuracy has been validated. See [WhisperX alignment](https://github.com/m-bain/whisperX/blob/main/whisperx/alignment.py) and [language metadata](https://github.com/m-bain/whisperX/blob/main/whisperx/utils.py).

Existing worker deployments must be updated to implement metadata discovery. A health response from an older deployment is not a substitute for language metadata.

### RunPod built-in list

The Swift app never runs the RunPod `capabilities` job, because each run can be billed. [`RunPodLanguages.swift`](../../apps/client-macos-swift/Sources/GdayMeetings/Services/RunPodLanguages.swift) contains the list that the worker's `capabilities()` returns with the WhisperX version pinned in the worker's `uv.lock` and the default multilingual model. The provider panel shows its size, and **Transcribe** maps the standard meeting choice to this list or rejects it before uploading audio.

[`export-languages.py`](../../apps/worker-audio-extraction/scripts/export-languages.py) regenerates the file. It downloads only the pinned WhisperX wheel and runs the worker's `capabilities.py` against WhisperX's metadata, without installing PyTorch. Regenerate it whenever `capabilities.py` or the WhisperX pin changes.

A deployed worker can differ from the built-in list, for example when it runs older code, another WhisperX version, or an English-only `.en` model. This drift is accepted: if the worker cannot handle a listed language, the transcription job fails and the app shows the worker's error. The `capabilities` operation remains available to the website and other clients.

## Swift interface

`TranscriptionProvider.submit(tracks:language:diarize:)` returns a job ID. `status(jobID:)` returns pending, completed segments, or failure. `cancel(jobID:)` requests cancellation. The result type contains timed segments, track names, optional speaker labels, and validated voice embeddings; language and model metadata from the worker are not yet retained by this interface.

## RunPod audio worker

The endpoint is configurable and initially empty. Use the queue-based endpoint URL from RunPod's Serverless endpoint page. Requests authenticate with the configured `Authorization: Bearer <API key>` header. The adapter appends operation paths to the endpoint base.

| Operation | HTTP request | Expected result |
| --- | --- | --- |
| Check | `GET /health` | Worker and job statistics. This does not run the model. |
| Submit | `POST /run` | JSON containing `id` and `status`. |
| Poll | `GET /status/{id}` | State; `output` when completed, or an error when failed. |
| Cancel | `POST /cancel/{id}` | Cancellation response for that job. |

Submission body:

```json
{
  "input": {
    "tracks": [
      {
        "audio_url": "https://storage.example.com/audio/track.opus?token=TEMPORARY_CAPABILITY",
        "track_name": "microphone",
        "source_type": "mic"
      }
    ],
    "language": "en",
    "diarize": false
  }
}
```

The worker accepts downloadable audio URLs, not local filesystem paths or inline audio. The direct client uses an explicitly selected [Filedrop provider](file-transfer.md), linked by `uploadProviderID`, to upload local audio. Both providers must be enabled. Its temporary URLs must stay valid through queueing and download retries. The provider panels explain that Filedrop receives the recording and RunPod retrieves it, and that RunPod charges may apply. **Transcribe** starts this configured flow directly, without another upload confirmation. Anyone with the temporary download link can retrieve it until expiry. Do not choose a transfer host or upload audio during a connection check.

The worker returns `tracks`, a dictionary keyed by `track_name`, plus `language` and `model`. Track results contain `source_type`, `duration_secs`, and `segments`. Segments contain `start`, `end`, and `text`; optional `words` and `speaker` add alignment and speaker labels. See the complete [worker input and output](../../apps/worker-audio-extraction/README.md#input).

RunPod states include `IN_QUEUE`, `IN_PROGRESS`, `COMPLETED`, `FAILED`, `CANCELLED`, and `TIMED_OUT`. A completed response without the expected output is a protocol error. The worker's processing model is set by deployment configuration; the client's connection check does not select or verify that model.

RunPod retains asynchronous results for a limited period, so persist retrieved text locally. A health response does not guarantee model readiness or protect audio from the worker host. See RunPod's [request lifecycle](https://docs.runpod.io/serverless/endpoints/send-requests) and [operation reference](https://docs.runpod.io/serverless/endpoints/job-operations).

## Desktop job handling

The app saves the selected provider and endpoint, upload destination, uploaded track URLs and earliest expiry, the meeting language and resolved provider-code snapshots, submission state, and returned job ID in the meeting. A pending attempt keeps its original destinations. Before submitting, it checks both connections, validates upload limits, and reuses unexpired receipts. Expired receipts require a new upload.

Before sending a RunPod submission, the app records that its acceptance may be uncertain. A lost response must not cause an automatic repeat of paid work. Once a job ID is saved, Resume Transcription polls that job. The managed task continues polling until the provider returns a result or error, or the user stops waiting in Tasks. A pending response does not expire locally after five minutes. Provider result-retention limits still apply. The app validates that completed output contains exactly the submitted track names and valid timestamps.

Results are saved before application. If the transcript or speaker assignments changed during processing, the app retains the returned result and offers **Apply Saved Transcript…** with replacement confirmation. This protects current edits; a general history of all transcript versions remains future work. RunPod voice embeddings are retained with track-scoped speaker identities for local recognition. Language, model, and word-timing output are not yet retained in the meeting result.

## Gday Meetings website

The website adapter uses browser login, authenticated audio uploads, durable tasks, and stored transcript outputs. The website chooses its worker. Its [API reference](../../apps/server/docs/api.md) defines upload limits, task identifiers, and idempotency. The desktop client must not send the website user's token to the worker.
