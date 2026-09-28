---
title: Stream summaries and control To-Do extraction
date: 2026-09-27
status: implemented
scope: swift-summary-streaming
---

## Problem

Summary generation displayed no text until the complete response arrived. Summary action items always became To-Dos, without a setting to turn extraction off. The Summaries settings section contained two explanatory footnotes the user asked to remove.

## Implemented solution

Summary requests use streamed Chat Completions. Incremental text appears in the existing read-only Markdown panel, with updates limited to ten per second after the first chunk. A per-meeting draft stays in memory; only a complete response replaces the saved summary and adds To-Dos. Cancellation, truncated responses, provider errors, and conflicting summary edits clear the draft and keep the saved summary. Chat retains its existing request format.

Settings → Defaults → Summaries now contains the provider picker, Automatically Summarize, and Automatically Extract To-Dos. Both descriptive footnotes are removed. Extraction defaults on to preserve existing behavior and can be disabled independently of summary generation.

## Reasoning

The user’s annotated Defaults screenshot was inspected before edits. The parent captured and inspected the current Summary panel. The design preserves its heading, generation button, and quiet Markdown surface, replacing only the displayed content with the active draft during generation.

The stream decoder buffers UTF-8 lines across transport boundaries, handles CRLF, comments, multiline SSE data, and completion markers, and rejects incomplete output. Responses that ignore the streaming request and return JSON are read once without resubmitting. Network logging records one request outcome without response text. Explicit cancellation also closes the response connection. The final summary and task completion receipt are saved together.

The implementation uses the [OpenAI streaming guide](https://developers.openai.com/api/docs/guides/streaming-responses) and Apple’s [URLSession asynchronous byte API](https://developer.apple.com/documentation/foundation/urlsession/bytes%28for%3Adelegate%3A%29), available before the deployment target. The OpenAI Docs skill was used to verify the protocol.

## Technical debt

None added. Providers that return JSON rather than SSE remain supported but cannot display incremental text. Partial drafts are deliberately not durable because incomplete generation must not replace a saved summary.

## Notes

Tests exercise the production URLSession against loopback responses with delayed TCP chunks, including a split UTF-8 scalar, and verify draft visibility before persistence, complete saves, cancellation, truncation, conflicting edits, and enabled/disabled To-Do extraction. Parent owns the coordinated build, integrated test run, and changed-UI screenshots. Real third-party providers are not exercised by these tests.

Final integrated validation passed 365 tests across 73 suites, Preview build, formatting, lint, and diff checks. Existing Command Line Tools linker-search-path warnings remain. Current Summary baseline was captured before edits. Post-change screenshots and settings interactions remain unverified because the computer-use service returned `cgWindowNotFound` after Preview relaunch. The synthetic stream fixture is available for visual follow-up without network requests.
