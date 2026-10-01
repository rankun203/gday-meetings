---
title: Filedrop
date: 2026-09-26
status: active
scope: file-transfer-guide
---

# file-drop (optional direct-transfer helper)

The standard deployment uses [apps/server](../../apps/server) for durable CMS-managed files. This tool is retained for the separately configured direct RunPod client workflow; it is not a fourth core component.

Temporary file parking server. Upload once, download until expiry, auto-expire.

Designed for ephemeral file transfer between services — e.g., parking audio files for a GPU worker to download.

The app-facing [file-transfer protocol](../../docs/protocols/file-transfer.md) describes explicit provider selection, task consent, connection checks, and download-link access. This service supports temporary transfer; it does not implement the meeting Playback or Search capabilities.

## Quick start

```bash
# Direct
cargo run -- --api-key YOUR_SECRET_KEY

# Docker Compose
API_KEY=YOUR_SECRET_KEY docker compose up
```

## API

### Upload a file

```bash
curl -X POST 'http://localhost:8199/upload?filename=meeting.opus' \
  -H "Authorization: Bearer YOUR_SECRET_KEY" \
  --data-binary @meeting.opus
```

Response:
```json
{
  "id": "ec4ae724-9201-42ee-8447-0c84cb1efed2",
  "url": "/d/ec4ae724-9201-42ee-8447-0c84cb1efed2",
  "filename": "meeting.opus",
  "size": 8421376,
  "size_human": "8.0 MB",
  "expires_in_secs": 600
}
```

API key can also be passed as a query parameter: `?api_key=YOUR_SECRET_KEY`

### Download a file

```bash
curl -o meeting.opus http://localhost:8199/d/ec4ae724-9201-42ee-8447-0c84cb1efed2
```

No API key required for downloads. Files remain available until expiry so interrupted transfers can retry.

### Storage info

```bash
curl http://localhost:8199/info
```

Response:
```json
{
  "storage_dir": "/data/storage",
  "file_count": 1,
  "total_size_bytes": 8421376,
  "total_size_human": "8.0 MB",
  "free_space_bytes": 304546349056,
  "free_space_human": "283.6 GB",
  "max_file_size_bytes": 104857600,
  "max_file_size_human": "100.0 MB",
  "allowed_extensions": ["mp3", "opus"],
  "expiry_secs": 600
}
```

### Health check

```bash
curl http://localhost:8199/health
# {"status":"available"}
```

Health and information routes do not verify the API key. The desktop adapter also sends `POST /upload` with the key but no filename or body: authentication runs first, then a correct key returns the documented missing-filename HTTP 400 before any file is created. The adapter matches that exact error. This credential check does not upload content. Download links allow anyone with the link to retrieve the audio until expiry; the service has no explicit delete endpoint.

## Error responses

| Status | When |
|--------|------|
| 400 | Bad extension, file too large, empty file, missing filename |
| 401 | Missing or invalid API key |
| 404 | File not found or expired |

Example:
```json
{"error": "File extension 'exe' not allowed. Allowed: [\"mp3\", \"opus\"]"}
```

## CLI options

| Flag | Default | Description |
|------|---------|-------------|
| `--api-key` | (required) | Secret key for uploads |
| `--port` | `8199` | Port to listen on |
| `--host` | `0.0.0.0` | Host to bind to |
| `--storage-dir` | `./storage` | Directory for parked files |
| `--max-size` | `104857600` (100MB) | Max file size in bytes |
| `--ext` | `mp3,opus` | Allowed extensions (comma-separated) |
| `--expiry-secs` | `86400` (24h) | Auto-delete after this many seconds |

## Behavior

- Files are deleted after **expiry** (default 24 hours); repeated downloads are allowed until then
- Uploads stream to disk — large files don't consume RAM
- Size limit enforced both via `Content-Length` header (early reject) and mid-stream (kills upload if exceeded)
- Storage info printed to logs after every upload/expiry
