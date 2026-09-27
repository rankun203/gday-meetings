---
title: Server API
date: 2026-09-26
status: active
scope: server-contracts
---

# Platform API v2

`/api/platform` accepts user OAuth tokens for the exact platform audience with `meetings:read` on GET and `meetings:write` on task submission/upload. The worker output callback requires its own task-scoped token. Public task mutation through PATCH is not supported (405). Failed authentication returns 401. Invalid input returns 400. Missing records return 404. JSON requests are limited to 20 MiB. There is no automatic result retention limit.

- `GET /api/platform/capabilities` → `{ "durableTasks": true, "meetingImports": true, "meetingImageArtifacts": true, "transcription": true, "version": 2, "protocolVersion": 1, "transcriptionLanguages": [{ "code": "en", "name": "English" }], "transcriptionLanguagesError": null }`. The language array comes from the configured worker; this example is not a fixed catalog. `transcription` is false until a worker is configured. Missing or failed metadata returns a null list and an explanatory error while preserving other capability fields. See [language discovery](../../../docs/protocols/transcription.md#discover-supported-languages) for validation, polling, and cache rules.
- `POST /upload?filename=recording.wav`, raw bytes and authorized upload credentials → `{ "url": "/files/uuid.wav?token=..." }`, status 201. Supported suffixes: wav, flac, mp3, m4a, ogg, opus, mp4, webm, aac. Maximum file size is 500 MB (500,000,000 bytes); `MAX_UPLOAD_BYTES` may lower this limit but cannot raise it. Prefer compressed Opus, M4A or MP3; WAV remains supported. Uploads stream to a temporary file and publish only after complete. An audio-file CMS record retains original filename, size, and content type.
- `GET /files/:storageKey?token=...` downloads audio. The capability URL works without a user session, supports HEAD and one HTTP byte range, and has no expiry. Treat it as a secret. Range requests outside the file return 416.
- `POST /api/platform/tasks` accepts `{ "externalId": "client-session-id", "title": "Planning", "idempotencyKey": "stable-attempt-id", "inputs": [{ "url": "https://gdaymeetings.com/files/...", "trackName": "mic", "sourceType": "mic", "channels": 1 }] }`. The server validates inputs, persists the task, and owns execution. Returns `{ "id": "uuid", "status": "PENDING", "executionState": "QUEUED" }`. It does not return worker callback credentials.
- Worker-only `POST /api/platform/tasks/:id/outputs` uses the task-scoped Bearer token provided directly by the server to the worker. It accepts `{ "type": "TRANSCRIPT_OUTPUT", "body": { "tracks": { "mic": { "segments": [{ "start": 0, "end": 1, "text": "Hello" }] } } } }`. Types are uppercase letters, digits, and underscores (max 64 characters). Task/type is unique; repeated callbacks preserve the first body. A 2xx response confirms server persistence. RunPod workers require this before reporting success; local HTTP workers commit output to their job database first, allowing server polling to recover failed callback delivery. Retries also repair task/search projection after interrupted writes.
- `GET /api/platform/tasks/:id` returns task status, inputs, and an `outputs` array of `{ "id", "type", "body", "downloadURL" }`; outputs is empty until persisted.
- `GET /api/platform/tasks/:id/outputs/:outputId` downloads the original JSON body with an attachment header.
- `GET /api/platform/meetings/search?query=budget` returns `{ "meetings": [{ "id", "externalId", "title", "transcript", "updatedAt" }], "total": 1 }`. Case-insensitive substring matching depends on the selected database collation. Query is 1–500 characters. Maximum 30 results.

## Server-managed transcription

Authenticated desktop clients POST a task with the meeting and input fields, a required attempt key, and optional execution options:

```json
{
  "idempotencyKey": "stable-local-attempt-id",
  "executionOptions": { "language": "auto", "diarize": true }
}
```

Only signed audio URLs uploaded to this server instance are accepted. The server verifies stored audio records before enqueueing. The response contains `id`, `status`, and `executionState`; output callback secrets stay on the server. Repeating the same user/session/idempotency key and request returns the existing task; different inputs under that key return 409. Use a new key for an intentional new transcription attempt.

Configure the local HTTP worker or `RUNPOD_ENDPOINT_URL` and `RUNPOD_API_KEY` on the server; see [worker configuration](architecture.md#local-standalone-worker). The persistent queue submits and polls independently of the desktop app. Clients poll GET task and download `TRANSCRIPT_OUTPUT` from the outputs array. A missing worker submission acknowledgement becomes `SUBMISSION_UNKNOWN`; the server waits for the worker callback and does not automatically submit a duplicate. Check the worker/provider before creating a replacement attempt.

Payload's own `/api/meetings`, `/api/tasks`, etc. require an authenticated CMS account. These are administration APIs, separate from the scoped platform API. Login and first-user setup are managed by Payload.

## Hosted MCP

`POST /mcp` uses the MCP SDK's Streamable HTTP protocol, separate from the REST API. Use an OAuth access token issued after Payload login and consent, together with standard MCP content negotiation headers (`Content-Type: application/json`, `Accept: application/json, text/event-stream`). Shared keys do not authorize client API or MCP requests. MCP tokens cannot upload or submit tasks; desktop tokens use a different audience and scopes.

The endpoint supports initialize, notifications (202), tools/list, and tools/call through the SDK. Its single tool is `search_meetings` with `{ "query": "budget" }`. Responses use JSON and no session ID; authenticated GET and DELETE requests return 405 with `Allow: POST`. Requests are limited to 64 KiB and responses are non-cacheable. Invalid credentials return 401 with a Bearer challenge; mismatched Host or Origin return 403. The Host header must match `SERVER_URL`, and a supplied Origin must match its origin exactly. The Bearer challenge points to OAuth discovery; see [authorization](mcp.md). Cross-origin browser access is not enabled.

## Import existing local meetings

Check authenticated capabilities for `meetingImports: true` before uploading migration audio. `meetingImageArtifacts: true` additionally permits the raster image artifacts below.

`POST /api/platform/meetings/import` requires the platform audience and `meetings:write`. It archives an existing recording without creating a task, contacting RunPod, or submitting worker output. The JSON body (20 MiB maximum) contains:

- `externalId`, `title`, optional ISO `recordedAt`, and optional `metadata` JSON for related people, speaker embeddings, tags, and other source context.
- `artifacts`: a map from safe basenames ending in `.json`, `.md`, or `.txt` to original JSON values or strings. Preserve all source artifacts, including the edited transcript, raw extraction, summaries, todos, notes, and waveforms. Text artifact dotfiles and paths are rejected. Image keys may use contained `assets/` paths and the extensions PNG, JPEG, GIF, WebP, HEIC, HEIF, TIFF, or BMP. Each image value is `{encoding:"base64",mediaType,data,sha256,size}`. The server verifies canonical base64, raster signature, matching extension/MIME type, SHA-256, and decoded byte count. Traversal and control characters are rejected. The per-image decoded limit is 15 MiB; the complete JSON request, including base64 expansion, remains limited to 20 MiB.
- `audio`: an array of `{filename,url,sha256,size}`. Upload files first through `/upload`; the import verifies the same-origin signed capability, native audio record, streamed SHA-256, and exact byte size. Empty arrays are supported for meetings without audio.
- `importKey`: a lowercase 64-character SHA-256 identifying the stable source snapshot. Audio URLs are excluded from the caller's source snapshot hash because uploads can be resumed.

The response is `{id,externalId,importKey,audioCount,artifactCount}`. Repeating the same external ID and snapshot is idempotent. A different snapshot, changed content under the same key, or an existing meeting without an import archive returns 409; imports never overwrite an existing meeting. The CMS stores native audio relationships and immutable source artifacts, while edited transcript segments supply searchable text (raw extraction is the fallback when no edited transcript exists).

`GET /api/platform/meetings/import/:externalId` requires `meetings:read` and returns the same summary after verifying archived content and rehashing every retained audio file. Missing imports return 404; altered archives, removed audio metadata, or missing/corrupt files return 409. Mark migration complete only after this readback matches the expected key and counts. Local source files remain backups until an explicit retention decision.

`GET /api/platform/meetings/import/:externalId/artifacts/notes.md` downloads an archived text artifact. A sibling path such as `artifacts/assets/board.png` downloads its original image bytes, including nested asset paths. Both require the same authenticated `meetings:read` access and verify the archive before returning content. Responses use `Content-Disposition: attachment`, `X-Content-Type-Options: nosniff`, and private/no-store caching. Text is returned as plain text or JSON, never executable HTML. A client can save notes and their relative `assets/` files together for use in a Markdown reader. External image URLs are not fetched. Image bytes participate in the immutable request digest; changing them changes the snapshot and a conflicting retry returns 409. Image data uses existing artifact JSON storage, so no database migration is required.
