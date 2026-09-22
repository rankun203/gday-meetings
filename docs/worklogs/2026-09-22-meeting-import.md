---
date: 2026-09-22
title: Archive existing local meetings into GdayMeetings
status: implemented
---

Problem: Existing local recordings and edited artifacts must be preserved in the CMS without retranscription or fabricated worker tasks.

Implemented solution: OAuth-scoped POST/GET meeting import endpoints preserve source metadata, arbitrary safe JSON/Markdown/text artifacts, and native audio relationships. Imports validate platform audio capabilities and stream byte counts/SHA256 before committing. A unique external ID and immutable import key/digest provide repeat-safe creation and conflict protection. Readback rechecks retained archive content and every audio file before reporting verified counts. Edited transcript text takes precedence over raw extraction for search; complete originals retain speaker references and embeddings. Empty-audio meetings are supported. SQLite and Postgres have generated migrations and snapshots.

Reasoning: Imports are meeting archives, not transcription jobs. Separating them prevents accidental RunPod costs or overwriting newer CMS content. Snapshot identity excludes upload URL details, allowing interrupted uploads to resume while content identity remains stable. Native audio relationships provide CMS navigation and respect existing file revocation behavior.

Validation: Actual OAuth + upload + import/readback tests pass against SQLite and PostgreSQL17 using production migrations. Coverage includes original artifact preservation, edited transcript search, audio checksum/size mismatch, corrupted retained audio, same-key retries, concurrent imports, conflicting existing records, safe filenames, audio-less archives, and absence of task creation. TypeScript passes. Follow-up review made the audio relationship nullable in both migration dialects so native deletion can set the foreign key to null; readback then fails closed with 409. SQLite and PostgreSQL tests confirm both the native file deletion and missing-link response. Archive canonicalization uses code-point key comparison independent of deployment locale.

Technical debt: Readback rehashes audio on every request, deliberately trading I/O for reliable migration verification; a future large-scale archive integrity service could cache verified digests with immutable file storage. Failed imports can leave previously uploaded native audio records unattached; source checkpoints permit reuse, and administrators may delete confirmed orphan uploads after migration. Automatic orphan deletion is deferred to avoid deleting recordings still in flight.
