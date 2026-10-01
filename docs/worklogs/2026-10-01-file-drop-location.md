---
title: Move Filedrop into apps
date: 2026-10-01
status: complete
scope: repository-layout
---

**Problem:** Filedrop lived under `tools` despite being an independently deployed app.

**Implemented solution:** Moved `tools/file-drop` to `apps/file-drop` and updated the repository layout, architecture, and file-transfer protocol references.

**Reasoning:** Keep deployable apps together. The package, binary, Docker configuration, and runtime behavior remain unchanged. Historical worklogs retain their original paths.

**Technical debt:** None.

**Notes:** Both Rust tests passed from the new path. The locked release build passed without warnings. `git diff --check` passed. Remaining references to the old path are historical worklogs. Docker deployment was not exercised.
