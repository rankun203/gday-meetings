---
date: 2026-09-22
title: Verify OAuth-only platform access
status: implemented
---

Problem: Platform regression tests still exercised an invented shared-key ingestion compatibility path instead of the required canonical user login.

Implemented solution: Platform tests obtain a real user access token through maintained provider login, dynamic registration, consent, and S256 code exchange. A reusable OAuth fixture lives in tests/helpers/oauth.ts. Durable callback, task-scoped capability isolation, byte-range downloads, audio deletion/revocation, empty transcript projection and concurrent ordering tests seed internal task records directly. Negative cases explicitly set the removed shared-key environment variable and require denial for uploads, reads, and submissions. User clients cannot select client-side execution or mutate task state through public PATCH.

Reasoning: Public authorization is tested through the same standard grant as desktop clients. Internal projection fixtures stay independent of RunPod configuration and cannot accidentally preserve unsupported public creation behavior.

Technical debt: None. MCP and platform suites share the OAuth grant fixture. No shared-key compatibility is preserved.

Validation: TypeScript passes. The MCP suite passes after consolidating the grant fixture. Final platform regression run is recorded by the parent after its coordinated API removal lands.
