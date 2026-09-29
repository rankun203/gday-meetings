---
title: File transfer protocol
date: 2026-09-26
status: active
scope: supporting-transport-contract
---

# File transfer

## Purpose

Make selected local audio temporarily available to a processing worker. File transfer supports [transcription](transcription.md); it does not provide a searchable meeting library or remote [Playback](playback.md).

## Contract

Input is a selected local file, filename, media type, and destination. The result identifies the uploaded object and supplies a download URL, byte count, and expiry. The URL must remain available while the worker queues and retries downloads.

A RunPod provider references its chosen file-transfer provider through `uploadProviderID`. Both providers must be explicitly configured and enabled. There is no default transfer host. The provider panels briefly name both destinations: the transfer provider receives audio, and RunPod receives its download URL and processes the audio.

Follow the [shared provider rules](README.md). Saving settings, changing the selected transfer provider, and opening either provider panel must not upload a file. Clicking **Transcribe** starts the configured upload and transcription in one action. Do not show a recurring confirmation dialog. Selecting a destination does not authorize automatic uploads of future recordings.

## Operations and results

| Operation | Result |
| --- | --- |
| Check service | Current reachability without uploading content. |
| Read limits | Accepted extensions, maximum file size, and expiry. |
| Upload selected audio | Object ID, downloadable URL, stored byte count, and expiry. |
| Download | Complete media bytes, or an expired/not-found response. |
| Delete, when supported | Confirmation; otherwise retain the reported expiry. |

Validate that returned URLs use the expected destination and transport before passing them to a worker. Keep download URLs out of logs and user-facing errors. Upload retries may create new objects; do not claim idempotency unless the service implements it.

## Swift interface

`FileTransferProvider.upload(file:)` returns `ProviderResult<FiledropUpload>`. Its value contains the download URL and expiry time, and its required `dataFlow` receipt records the destination, filename, transfer sizes, and timing without retaining the signed URL. The `fileTransfer` capability identifies providers that can supply this transport. `uploadProviderID` links a RunPod provider to its selected transfer provider.

## Filedrop adapter

The implementation follows the [Rust client's direct transcription flow](../../apps/client-macos-rust/src/server/routes.rs) and the [file-drop service](../../tools/file-drop/README.md).

| Operation | Request | Result |
| --- | --- | --- |
| Check service | `GET /health` | HTTP 200 with `{"status":"available"}`, or HTTP 503 with `{"status":"unavailable"}`. |
| Check credentials | `POST /upload`, Bearer key, no filename and no body | The expected missing-filename HTTP 400 confirms authentication without creating a file. |
| Read limits | `GET /info` | `max_file_size_bytes`, `allowed_extensions`, and `expiry_secs`, with storage statistics. |
| Upload | `POST /upload?filename=track.opus`, raw file body, `Authorization: Bearer <API key>` | `id`, `url`, `filename`, `size`, and `expires_in_secs`. |
| Download | `GET /d/{id}.{extension}` | Audio bytes until expiry. |

Health and information requests are read-only and do not require authentication. The adapter also checks credentials using `POST /upload` with the Bearer key, no filename, and no body. The service validates authentication before checking the required filename and before opening a file. A correct key therefore returns HTTP 400 with `{"error":"filename required (?filename=name.opus or Content-Disposition header)"}`. The adapter must match this response exactly; another HTTP 400 does not establish authentication. Missing or rejected keys return HTTP 401. This probe sends no recording and creates no file.

Run these checks after Save and when the provider panel opens. A successful result confirms service access and the saved key; it does not upload test content.

The upload response supplies a relative download URL. Resolve it against the configured service address and verify its origin. The Swift client supplies API keys in the Authorization header, not the query string.

Download links contain a random UUID. Possession of the link grants access until expiry; the service does not require a download API key. They are not account-authenticated storage or end-to-end encryption. The service host can read uploaded audio. The provider panel must explain this access and must not describe the destination as encrypted storage.

The current service has no explicit deletion or upload-idempotency endpoint. It does not delete audio after the first download: repeated downloads remain available until the configured expiry. At expiry, new downloads return 404; a background task attempts file deletion every 10 seconds. Canceling transcription does not remove the parked audio. If a URL expires before the worker downloads it, a new authorized upload and transcription attempt are needed.

Deletion is best effort in the current implementation. Failed filesystem deletions are not retried, and the in-memory file index is not restored after restart, so files left on disk may need operational cleanup. These limits apply to the repository implementation; a separately deployed version may behave differently.
