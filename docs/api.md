# Platform API v2

`/api/platform` accepts user OAuth tokens for the exact platform audience with `meetings:read` on GET and `meetings:write` on task submission/upload. The worker output callback requires its own task-scoped token. Public task mutation through PATCH is not supported (405). Failed authentication returns 401. Invalid input returns 400. Missing records return 404. JSON requests are limited to 20 MiB. There is no automatic result retention limit.

- `GET /api/platform/capabilities` → `{ "durableTasks": true, "transcription": true, "version": 2 }` (`transcription` is false until RunPod is configured).
- `POST /upload?filename=recording.wav`, raw bytes and authorized upload credentials → `{ "url": "/files/uuid.wav?token=..." }`, status 201. Supported suffixes: wav, flac, mp3, m4a, ogg, opus, mp4, webm, aac. Limit defaults to 2 GiB (`MAX_UPLOAD_BYTES`). Uploads stream to a temporary file and publish only after complete. An audio-file CMS record retains original filename, size, and content type.
- `GET /files/:storageKey?token=...` downloads audio. The capability URL works without a user session, supports HEAD and one HTTP byte range, and has no expiry. Treat it as a secret. Range requests outside the file return 416.
- `POST /api/platform/tasks` accepts `{ "externalId": "client-session-id", "title": "Planning", "idempotencyKey": "stable-attempt-id", "inputs": [{ "url": "https://.../files/...", "trackName": "mic", "sourceType": "mic", "channels": 1 }] }`. Gday validates inputs, persists the task, and owns execution. Returns `{ "id": "uuid", "status": "PENDING", "executionState": "QUEUED" }`. It does not return worker callback credentials.
- Worker-only `POST /api/platform/tasks/:id/outputs` uses the task-scoped Bearer token provided directly by Gday to RunPod. It accepts `{ "type": "TRANSCRIPT_OUTPUT", "body": { "tracks": { "mic": { "segments": [{ "start": 0, "end": 1, "text": "Hello" }] } } } }`. Types are uppercase letters, digits, and underscores (max 64 characters). Task/type is unique; repeated callbacks preserve the first body. Workers must wait for a 2xx response before reporting success. Retries also repair task/search projection after interrupted writes.
- `GET /api/platform/tasks/:id` returns task status, inputs, and an `outputs` array of `{ "id", "type", "body", "downloadURL" }`; outputs is empty until persisted.
- `GET /api/platform/tasks/:id/outputs/:outputId` downloads the original JSON body with an attachment header.
- `GET /api/platform/meetings/search?query=budget` returns `{ "meetings": [{ "id", "externalId", "title", "transcript", "updatedAt" }], "total": 1 }`. Case-insensitive substring matching depends on the selected database collation. Query is 1–500 characters. Maximum 30 results.

## Gday-managed transcription

Authenticated desktop clients POST a task with the meeting and input fields, a required attempt key, and optional execution options:

```json
{
  "idempotencyKey": "stable-local-attempt-id",
  "executionOptions": { "language": "auto", "diarize": true }
}
```

Only signed audio URLs uploaded to this Gday instance are accepted. The server verifies stored audio records before enqueueing. The response contains `id`, `status`, and `executionState`; output callback secrets stay on the server. Repeating the same user/session/idempotency key and request returns the existing task; different inputs under that key return 409. Use a new key for an intentional new transcription attempt.

Set `RUNPOD_ENDPOINT_URL` and `RUNPOD_API_KEY` on Gday. The persistent queue submits and polls independently of the desktop app. Clients poll GET task and download `TRANSCRIPT_OUTPUT` from the outputs array. A missing submission acknowledgement becomes `SUBMISSION_UNKNOWN`; Gday waits for the worker callback and does not automatically submit a duplicate. Check RunPod before creating a replacement attempt.

Payload's own `/api/meetings`, `/api/tasks`, etc. require an authenticated CMS account. These are administration APIs, separate from the scoped platform API. Login and first-user setup are managed by Payload.

## Hosted MCP

`POST /mcp` uses the MCP SDK's Streamable HTTP protocol, separate from the REST API. Use an OAuth access token issued after Payload login and consent, together with standard MCP content negotiation headers (`Content-Type: application/json`, `Accept: application/json, text/event-stream`). Shared keys do not authorize client API or MCP requests. MCP tokens cannot upload or submit tasks; desktop tokens use a different audience and scopes.

The endpoint supports initialize, notifications (202), tools/list, and tools/call through the SDK. Its single tool is `search_meetings` with `{ "query": "budget" }`. Responses use JSON and no session ID; authenticated GET and DELETE requests return 405 with `Allow: POST`. Requests are limited to 64 KiB and responses are non-cacheable. Invalid credentials return 401 with a Bearer challenge; mismatched Host or Origin return 403. The Host header must match `SERVER_URL`, and a supplied Origin must match its origin exactly. The Bearer challenge points to OAuth discovery; see [authorization](mcp.md). Cross-origin browser access is not enabled.
