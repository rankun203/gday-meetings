---
title: Summarization protocol
date: 2026-09-26
status: active
scope: capability-contract
---

# Summarization

## Purpose

Produce a summary from a specified transcript and optional notes. The UI calls this capability **Summaries**.

## Contract

Input contains the transcript text, explicitly included notes, summary instructions, and the selected model. The app must know which meeting and transcript version supplied that text. Audio and unrelated meetings are excluded.

The result is summary text associated with that input. Generated text must not be treated as verified meeting facts. The Rust client supports editing summaries; the Swift client displays summaries as read-only Markdown. Preserve user edits if the source changes while a request is running; require a deliberate replacement rather than silently overwriting a newer summary.

Follow the [shared provider rules](README.md). Sending text for a summary does not enable [Search](search.md) or upload original audio for [Playback](playback.md).

## Operations and results

| Operation | Result |
| --- | --- |
| Check connection | An authenticated response without meeting content. |
| Generate summary | Summary text or a task-specific error. |
| Cancel, when supported | Cancellation acknowledgement; otherwise stop waiting without claiming remote processing stopped. |

Empty responses, missing completion content, and malformed result objects are failures. Explain rejected credentials, unavailable models, input limits, and service failures separately where the transport provides enough information.

## Swift interface

`SummarizationProvider.summarize(transcript:instructions:)` returns text. The language-model adapter also accepts message arrays for the app's summaries and chat. The initial interface does not carry a persisted transcript version; the caller owns meeting selection and protection of edits. The app rejects a generated result if the summary, transcript, or notes changed during processing. The earlier saved summary is preserved. That rejected result is not retained; inputs do not yet have a persisted revision link.

## OpenAI-compatible adapter

The configured endpoint is an API base URL. The adapter checks `GET /models` with the configured Bearer API key and submits messages to `POST /chat/completions`. The provider panel reads `data[].id`, and `name` when present, from the same `GET /models` response to fill the **Model** menu. It lists models when the panel opens for an enabled provider, and about 0.8 seconds after the endpoint URL or API key is edited, provided both are present and the URL is valid. It never lists them automatically for a disabled provider that is not being edited. The list is saved per provider and endpoint, shown immediately on the next open, and refreshed in the background. The **Model** field accepts any typed name, because some compatible endpoints omit or restrict `/models`; a saved model missing from the list stays selected and is marked “(not listed)”. Requests specify the configured model and include only the chosen context and instructions. The adapter extracts the assistant's text from the completion response.

Compatibility with this API supports this adapter's language-model operations. It does not imply support for transcription, diarization, meeting indexes, or audio storage. A model-list response confirms access to that route; it does not prove the configured model will accept a completion request.

The completion API does not provide the app with a durable job identifier or a general remote cancellation guarantee. Do not automatically resubmit after an ambiguous submission failure. The provider's retention and billing policies apply to submitted text and images.

## Swift summary prompt

Each OpenAI-compatible provider stores its own **Summary Prompt** in Service Providers. **Restore Default** restores structured-summary instructions based on `chat/summarize.rs`, with source-image citations: title, description and duration, attendees, checkbox action items, topics, and timestamp citations. The app adds the meeting language and current local time at request time. Custom prompts replace those default instructions. Chat uses its separate instructions.

Summary input includes the meeting title, start time, duration, notes, participant names and notes, and timestamped transcript. It excludes the previous generated summary. The Swift data model has no tag notes. Older customized global Summary Instructions migrate to the selected OpenAI-compatible provider unless that provider already has a prompt. Without a selection, the first OpenAI-compatible provider without a custom prompt receives them. If no provider can receive them, settings retain the instructions until a suitable provider is added or selected; saving retries migration. The old stock Swift instructions are replaced by the Rust default; the global setting is no longer written.

## Automatic summaries in Swift

**Automatically Summarize** in Defaults starts off. When enabled, a successfully saved live transcript at recording stop or an applied provider transcription triggers a summary through the selected summary provider. A later provider transcript can generate another summary after the live transcript. If a summary is already running for the meeting, the newest pending transcript waits for it to finish. Turning the setting on does not process existing meetings.

The Tasks queue runs one summary at a time, independently of transcription. A queued summary reads the latest saved transcript when it starts, so changes received before it starts are combined into that request. Turning off Automatically Summarize prevents queued automatic summaries from starting. Tasks and their outcomes are saved locally in `tasks.jsonl`. A queued, unsent summary can recover automatically; an interrupted request requires an explicit retry because the provider may already have processed it.

Summary requests use `stream: true`. The app parses server-sent events and presents the accumulated text in the existing Markdown panel. Partial text remains in memory; only a complete, nonempty response replaces the saved summary. Cancellation or malformed/truncated streams preserve the earlier summary. A provider that returns JSON in the same response is accepted without issuing another paid request. **Automatically Extract To-Dos** controls extraction from completed summaries and defaults to on.

## Notes images in Swift summaries

The provider panel has an **Image Input** setting beneath Model. **Automatic** uses the selected model’s explicit `architecture.input_modalities` from the provider’s model list, as documented by [OpenRouter](https://openrouter.ai/docs/api/api-reference/models/get-models). It does not infer support from model names. Standard OpenAI model objects do not advertise input modalities, and compatible services may omit them. **Supports Images** and **Text Only** provide explicit overrides scoped to the exact endpoint and model; changing either returns to Automatic.

An image-containing summary with unknown support stops before sending meeting content and asks the person to choose a setting. If metadata is missing, the app first tries the free model-list request. Cached metadata is scoped to the provider and endpoint and refreshed in Settings. Text-only meetings keep their existing request format. Text Only sends Notes text with a clear instruction that referenced images were not inspected.

When image support is established, the app reads the original local images referenced by the Notes editor’s Markdown or resized HTML image blocks, deduplicates their paths, and attaches each image beside its relative `assets/` path. It never fetches remote images. The loader rejects traversal, symbolic links, missing or invalid images, source files over 100 MB, and images over 100 million pixels. Preparation runs off the main actor and responds to cancellation between images. Images are converted to JPEG at quality 0.9 with a maximum dimension of 2,400 pixels; the local original is unchanged. Up to 20 unique images and 20 MB of compressed image bytes are supported. Base64 increases the request size. Exceeding a limit fails before submission with a recovery action; no images are silently omitted. Providers may impose lower limits, which remain request errors.

Both streaming and nonstreaming Chat Completions requests use text and `image_url` parts containing base64 data URLs, following the [provider image-input contract](https://openrouter.ai/docs/guides/overview/multimodal/image-understanding). Each image part is paired with its relative path. The default prompt asks for descriptive Markdown links to relevant source images. An additional instruction preserves that citation convention with custom prompts and treats image content as meeting evidence, not instructions.

Summary image links open the original in a resizable native Quick Look window. Only readable images under the meeting’s `assets/` folder can open; absolute paths, traversal, symlinks, and other URL schemes cannot open local files. Saved summary references retain assets even after an image is removed from Notes. Exports, imports, and archive manifests include summary-referenced assets.

JSON fallback responses with an explicit completion reason other than `stop` are rejected as incomplete. Compatible providers that omit the reason remain supported. No fallback issues a second paid request.
