# Shared identity and recording flow

GdayMeetings is the source of users and access permissions. Payload Admin manages those accounts. The hosted identity module provides standard OpenID Connect/OAuth login; optional external identity providers are linked sign-in methods for existing Gday users, not a separate source of application permissions.

The Rust meeting-notes app is a public OAuth client. It discovers Gday's issuer, opens browser login with PKCE, and stores refresh/access credentials in the daemon's private server-side storage. The browser UI receives connection status, not tokens. The same hosted login serves MCP clients with a separate read scope and resource audience.

After login, the desktop app uploads recording tracks and submits an idempotent transcription task. Gday persists the task before contacting RunPod, owns execution and status recovery, and retains typed outputs. The daemon downloads the durable result for its existing local transcript interface. RunPod credentials belong to Gday deployment configuration for this flow.

The authentication boundary accepts a standard principal (issuer, subject, current canonical user, scopes, audience). Feature code consumes that principal; it does not implement provider-specific login or exchange cookies between apps. External identity integration cannot silently create privileged users or bypass canonical account removal.

MCP uses `mcp:read` at `/mcp`. The desktop client uses `meetings:read` and `meetings:write` at `/api/platform`. Service-worker capabilities remain narrowly scoped to one task output or audio file. No shared-key client access or client-managed task execution is supported. Task submissions require an idempotency key; Gday alone manages execution and output callback credentials.

OAuth-only client access and Gday-owned execution are enforced in version 0.3.1. The Rust client and maintained Gday provider have been tested together using disposable local accounts.
