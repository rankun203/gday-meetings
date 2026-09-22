---
date: 2026-09-22
title: Recognize SQLite OAuth array storage during startup checks
status: released
---

Problem: Better Auth 1.7.5 creates string[] and number[] SQLite columns as TEXT, but its migration type comparison accepts only JSON-named types for arrays. Reopening an existing auth database prints false mismatches for OAuth scopes, redirect URIs, resources and related arrays. Fresh-database tests missed this restart-only warning. The reported image digest was 0.3.4; registry latest was independently verified as 0.3.6 when investigating.

Implemented solution: A version-pinned pnpm dependency patch makes the migration checker accept its own TEXT array representation on SQLite only. PostgreSQL and other dialect comparisons are unchanged. Docker copies patches before the frozen dependency install. A real OAuth regression creates a persisted database, reopens it, asserts there are no migration warnings or schema operations, compares persisted client records, and refreshes the existing token through a new auth instance. A deliberately incorrect INTEGER array column still warns.

Reasoning: Correct the type comparison instead of changing valid stored data or suppressing schema warnings. No auth database migration or reset is required.

Technical debt: Retained a narrowly scoped patch to Better Auth 1.7.5 because the installed migration checker disagrees with its SQLite DDL generator. The patch is locked and applied during every install; it must be reviewed when upgrading Better Auth. Remove it once an upstream release recognizes SQLite TEXT array storage and the restart regression passes unpatched.

Validation: The new regression reproduced the exact 17 OAuth array warnings without the patch, then passed with it. TypeScript and all 31 tests pass. Release 0.3.7 passed CI and both native architecture container checks (Actions run 35693977567). Anonymous registry verification confirms 0.3.7 and latest share digest sha256:7aaa13f9f96d685ded6dc4623e39f520a5db89efaf80bf02b0dd01b35fc20963, with exactly linux/amd64 and linux/arm64.
