---
date: 2026-09-22
status: complete
---

## Problem

MCP used a deployment-wide bearer secret. The user requested the ase-user-study login model, then clarified that Gday owns users, provides pluggable standard SSO to the Rust client, and executes transcription using server-only RunPod environment settings.

## Implemented solution

Use the maintained Better Auth OIDC/OAuth provider behind an identity adapter, with canonical Payload users and optional explicitly linked upstream login. Add login/consent/discovery, scoped MCP and desktop resource access, and desktop upload/task execution routes. User-based Local API calls respect collection access. Remove shared-token MCP access. Centralize environment validation, add both database migrations, prepare v0.3.0 and Compose configuration.

## Reasoning

Gday remains the source of user management while the library owns protocol implementation. MCP search and desktop uploads use separate audiences and scopes. A durable server execution queue lets transcription finish while the desktop is offline. Existing service clients retain their separate compatibility path.

## Technical debt

One shared workspace remains; members can read its meetings. Add membership/ownership filtering before multi-tenant use. JWT access tokens live five minutes: refresh-only revocation prevents renewal but does not revoke an existing JWT immediately; browser-session logout and canonical disable/delete reject applicable resource access immediately. A provider supporting immediate per-token revocation would be needed for a stricter requirement. Local audio storage and SQLite remain single-instance. Provider-managed auth migrations require one coordinated startup; use explicit release migration orchestration before horizontal scaling. External OIDC is configured and explicitly linked, but no real upstream tenant was supplied for live validation.

## Notes

Nine MCP/desktop integration tests pass: real login/consent/code exchange, SDK search, static-token rejection, audience separation, expiry/logout/disable/delete, refresh rotation/replay/revocation, complete discovery, scoped upload and idempotent queue creation. Environment validation tests pass. SQLite/Postgres task and identity migrations validated on disposable databases. Production typecheck/build and Docker build pass. Actual Rust-to-Gday integration passed native registration, canonical login, consent, EdDSA ID-token verification and initial/refreshed platform access. Full platform suite: 23 tests passed. Published v0.3.0 and latest for Linux AMD64/ARM64 via successful workflow 35687119914. Anonymous registry access verified; both tags resolve to sha256:f180b2e976c3e56d016b0fa350f85b52404f97b69954a719b23df7d4f67553d0. Pulled the published image and verified complete discovery, first-admin bootstrap and repeat denial, login, named consent page, PKCE exchange, five-minute token, authenticated MCP initialize and anonymous rejection. Test container and synthetic databases removed. Rust integration is committed locally at 431dc89 (37 default tests plus actual-provider integration passed). No live deployment target or RunPod credentials were supplied; no paid provider job was invoked.
