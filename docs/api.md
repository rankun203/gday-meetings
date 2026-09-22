# Platform API v1

All `/api/platform` endpoints use `Authorization: Bearer GDAY_API_TOKEN` except the task output callback, which requires its own task-scoped token. Failed authentication returns 401. Invalid input returns 400. Missing records return 404. JSON requests are limited to 20 MiB. There is no automatic result retention limit.

- `GET /api/platform/capabilities` → `{ "durableTasks": true, "version": 1 }`.
- `POST /upload?filename=recording.wav`, raw bytes and service Authorization → `{ "url": "/files/uuid.wav?token=..." }`, status 201. Supported suffixes: wav, flac, mp3, m4a, ogg, opus, mp4, webm, aac. Limit defaults to 2 GiB (`MAX_UPLOAD_BYTES`). Uploads stream to a temporary file and publish only after complete. An audio-file CMS record retains original filename, size, and content type.
- `GET /files/:storageKey?token=...` downloads audio. The capability URL works without service credentials, supports HEAD and one HTTP byte range, and has no expiry. Treat it as a secret. Range requests outside the file return 416.
- `POST /api/platform/tasks` accepts `{ "externalId": "client-session-id", "title": "Planning", "inputs": [{ "url": "https://.../files/...", "trackName": "mic", "sourceType": "mic", "channels": 1 }] }`. Every create is a new attempt, grouped under the meeting external ID. Returns `{ "id": "uuid", "status": "PENDING", "resultSink": { "url": "https://.../api/platform/tasks/uuid/outputs", "token": "task-scoped-token" } }`.
- `POST resultSink.url` using `Authorization: Bearer resultSink.token` accepts `{ "type": "TRANSCRIPT_OUTPUT", "body": { "tracks": { "mic": { "segments": [{ "start": 0, "end": 1, "text": "Hello" }] } } } }`. Types are uppercase letters, digits, and underscores (max 64 characters). Task/type is unique; repeated callbacks preserve the first body. Workers must wait for a 2xx response before reporting success. Retries also repair task/search projection after interrupted writes.
- `GET /api/platform/tasks/:id` returns task status, inputs, and an `outputs` array of `{ "id", "type", "body", "downloadURL" }`; outputs is empty until persisted.
- `PATCH /api/platform/tasks/:id` accepts optional `status` (`PENDING` or `FAILED`), `error`, and `runpodJobId`. Completed tasks cannot be downgraded by a late job-poll failure.
- `GET /api/platform/tasks/:id/outputs/:outputId` downloads the original JSON body with an attachment header.
- `GET /api/platform/meetings/search?query=budget` returns `{ "meetings": [{ "id", "externalId", "title", "transcript", "updatedAt" }], "total": 1 }`. Case-insensitive substring matching depends on the selected database collation. Query is 1–500 characters. Maximum 30 results.

Payload's own `/api/meetings`, `/api/tasks`, etc. require an authenticated CMS account. These are administration APIs, separate from the service contract. Login and first-user setup are managed by Payload.

## Hosted MCP

`POST /mcp` uses the MCP SDK's Streamable HTTP protocol, separate from the REST API. Send `Authorization: Bearer GDAY_MCP_TOKEN` and standard MCP content negotiation headers (`Content-Type: application/json`, `Accept: application/json, text/event-stream`). If `GDAY_MCP_TOKEN` is unset, the service token is accepted instead. A configured dedicated MCP token is never accepted by service mutation endpoints.

The endpoint supports initialize, notifications (202), tools/list, and tools/call through the SDK. Its single tool is `search_meetings` with `{ "query": "budget" }`. Responses use JSON and no session ID; authenticated GET and DELETE requests return 405 with `Allow: POST`. Requests are limited to 64 KiB and responses are non-cacheable. Invalid credentials return 401 with a Bearer challenge; mismatched Host or Origin return 403. The Host header must match `SERVER_URL`, and a supplied Origin must match its origin exactly. No OAuth discovery or cross-origin browser access is implemented.
