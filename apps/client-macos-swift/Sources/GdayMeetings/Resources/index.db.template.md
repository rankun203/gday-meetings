---
title: Disposable library database
date: 2026-10-05
status: generated
scope: local-library-index
---

<!-- gday-generated-index-guide -->

# Source files and database

The app generates this guide from its checked-in template and the installed SQLite schema. It updates the guide when the schema changes. Keep personal notes in a separate file.

Meeting folders, person and tag documents, and `tasks.jsonl` are authoritative. This database is a disposable projection. Do not write meeting content, task state, or provider credentials into it directly. Rebuild the index through the app after changing source files.

The default local library keeps `index.db` in its data folder. Custom library folders use a local cache keyed by the resolved folder path, including cloud folders. SQLite files and their WAL/SHM companions must not be synchronized. Source files and provider embedding artifacts may be synchronized separately.

One database contains independently versioned modules. Trusted in-app provider adapters may register tables under their own namespace; remote provider responses cannot supply SQL. A module upgrade rebuilds that module from source files without resetting unrelated modules. Old separate cache files may remain from an earlier app version; they are no longer opened.

Task rows contain offsets and digests into `tasks.jsonl`, not copied task payloads. Full-text search contains derived, readable passages from titles, notes, summaries, and transcripts. Treat this database as private meeting data even though it can be rebuilt.

# Installed modules

{{MODULES}}

# Installed schema

The following schema comes from `sqlite_schema`. FTS5 shadow tables and SQLite internal tables are omitted. Revision triggers detect concurrent writes before a staged rebuild is published.

```sql
{{SCHEMA}}
```
