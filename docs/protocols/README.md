---
title: Service provider protocols
date: 2026-09-26
status: active
scope: capability-contracts
---

# Service provider protocols

A provider is a configured connection or account. A capability is an operation that provider supports. Language is a meeting recording setting, not a provider capability or connection setting. The app calls a capability contract; an adapter translates it into the provider's API. Providers can implement capabilities independently.

These documents define the common meaning of requests and results. They also identify implemented adapters and remaining work. They do not define a new HTTP API that every provider must expose.

| Capability | Purpose |
| --- | --- |
| [Transcription](transcription.md) | Convert recording tracks into timed text. |
| [Diarization](diarization.md) | Assign speaker labels to time ranges. |
| [Summarization](summarization.md) | Summarize a specified transcript and optional notes. |
| [Search](search.md) | Index selected meeting text and retrieve matching passages. |
| [Playback](playback.md) | Store selected audio and provide authorized playback. |

[File transfer](file-transfer.md) is a supporting transport for URL-based workers. It is separate from the five meeting capabilities above.

The [meeting experience](../design/meeting-experience.md) describes provider settings, task defaults, and data destinations. The [Swift client guide](../../apps/client-macos-swift/README.md) describes setup. Existing [website APIs](../../apps/server/docs/api.md) and the [audio worker contract](../../apps/worker-audio-extraction/README.md) remain transport references.

## Swift implementation

The app contracts are declared in [`ServiceProviders.swift`](../../apps/client-macos-swift/Sources/GdayMeetings/Services/ServiceProviders.swift). `TranscriptionProvider`, `DiarizationProvider`, and `SummarizationProvider` have RunPod or language-model adapters. `SearchProvider`, `SearchIndexProvider`, and `PlaybackProvider` define extension points; remote search, indexing, and remote playback adapters are not implemented. The website does not advertise Search or remote Playback in the app. The app searches its local library; website sign-in, transcription, and archiving remain provider operations.

These initial Swift interfaces cover submission, result retrieval, and the operations listed in their declarations. The richer version and provenance requirements in these documents guide subsequent implementation; they are not a claim that every field is already persisted.

## Provider configuration

A provider has a stable identifier, kind, display name, endpoint, authentication settings, and supported capabilities. Display names are editable and must not identify stored credentials or results. Store secrets in Keychain, separately from ordinary settings. Never include secrets or signed audio URLs in logs.

Keep four decisions separate: what the provider supports, what the person enabled, whether it can currently be reached, and which task uses it. Adding a provider must not upload meeting content. A successful connection check does not authorize uploads or establish model accuracy, retention, or confidentiality.

Endpoints are entered by the person configuring the service. The RunPod endpoint has no default. Its field help must explain where to copy the endpoint URL in the RunPod console. Authentication fields are editable. A different address or account is a different data destination and requires a fresh connection check.

## Starting a task

Provider panels briefly explain what is sent, where it goes, temporary-link access, and applicable provider charges. Once a provider is configured and selected, **Transcribe** starts the upload and job in one click. Do not repeat these disclosures in a confirmation dialog for every transcription. Saving settings or checking a connection never starts a content upload.

Future Gday Cloud point quotes are a separate, unimplemented billing flow. They do not add a confirmation step to the current RunPod or website workflow.

## Connection checks

Every provider implements the same connection-check operation. Check an enabled provider after saving settings and whenever its detail panel opens. A check must be free metadata that sends only credentials. Never check a disabled provider, even on request. Use the saved configuration; discard late results if that configuration or the selected provider changes. A check must not submit inference, upload recordings, or send meeting text.

Show a status icon with text. Do not communicate status through color alone.

| State | Meaning |
| --- | --- |
| Not Checked | No result exists for the saved configuration. |
| Checking | A check is in progress. |
| Healthy | The adapter received the expected response. Each capability contract defines its authentication check. |
| Setup Required | A required address, credential, or setting is missing. |
| Connection Failed | The request failed or returned an unexpected response. |

Errors identify the field or operation and a recovery action. Distinguish rejected credentials, invalid addresses, unavailable services, and incompatible responses. Reopening an enabled provider's panel checks again; a previous success is not evidence of a current connection.

Requests that are free, send only credentials, and start no work may run automatically for enabled providers: connection checks, model lists, and website language lists. The Swift app ships RunPod's language list instead of running a billable discovery job. Anything that can be billed or starts provider work, such as a RunPod job, requires an explicit action and a nearby charge note. Disabled providers are never contacted automatically; the only exception is listing models while the person edits that provider's endpoint or key. UI Preview uses the same provider checks and can run deliberately started service jobs with test credentials. Its temporary library and in-memory credentials avoid Keychain prompts; opening or saving settings must not upload content.

## Shared contract rules

- A request identifies its meeting and source tracks or text. Time values are seconds on the original track timeline, including track offsets when the app combines results.
- Results retain their source identity. Providers must not silently replace recording files, transcript edits, or a different version of the input.
- A request names its destination. No adapter may fall back to another provider or broaden the submitted content after an error.
- Authentication applies to both submission and result retrieval. Remote transport uses HTTPS; loopback HTTP can serve local development.
- Cancellation is explicit and may fail. Stopping polling or disabling a provider does not establish that remote work stopped or that uploaded copies were deleted.
- Retry read operations after transient failures. Do not repeat a job submission after an ambiguous response unless the transport supplies an idempotency guarantee.
- Validate response types, identifiers, and time ranges before applying results. An HTTP success with malformed output is an error.
- Keep recording, local playback, and the local library available when a provider fails.

The [transcription protocol](transcription.md#discover-supported-languages) defines version 1 language metadata. Language lists come from providers, with no app fallback catalog. RunPod is the exception: the Swift app ships the list from this repository's worker. Other capability discovery and shared wire-level version negotiation remain future work; existing adapters use their documented APIs.
