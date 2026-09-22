---
date: 2026-09-22
task: Hosted MCP transport
status: complete
---

**Problem:** The initial MCP adapter required a local pnpm/stdio process. The user wanted a hosted web endpoint inside the recordings platform, like the reference Payload application.

**Implemented solution:** Replaced the stdio entry point with a stateless `/mcp` route backed by the official SDK's Web Standard Streamable HTTP transport. The single `search_meetings` tool calls local Payload search. A dedicated `GDAY_MCP_TOKEN` grants read-only MCP access; existing installations fall back to the service token when it is unset. Host/Origin checks use the configured public origin, body reads are bounded, and every response disables caching. Removed the local-process script and updated API, architecture, environment, and client setup documentation. The protocol server version follows package.json (0.2.0).

**Reasoning:** Match the reference project's single hosted route while using the maintained SDK for initialize, notifications, content negotiation, validation and tool dispatch. Fresh request-scoped servers avoid sticky-session requirements. A separate token avoids granting upload/task permissions to search clients.

**Technical debt:** Bearer configuration is deliberately simpler than the reference's OAuth server; clients that require OAuth discovery cannot connect yet. Add OAuth/scoped identities if delegated third-party access is required. No cross-origin browser support is included; ordinary server-side MCP clients connect without Origin. Add an explicit allowlist and CORS handling only if a browser client is needed. The shared service-token fallback retains compatibility but grants broad credentials to the client; operators should set the dedicated token.

**Validation:** Actual MCP SDK HTTP client exercises initialize, notification, tools/list and tools/call against a native HTTP server and a private SQLite fixture. Additional checks cover empty queries, anonymous/service-token rejection when dedicated credentials exist, untrusted host/origin, read-only token isolation from mutation auth, stateless 405, notification 202, malformed JSON, oversized bodies, and service-token fallback. Full platform suite passed (7 tests), as did formatting, typecheck, and the production build. A real Next standalone launch also passed SDK initialize (v0.2.0), tool listing, local Payload search, unauthenticated 401, and stateless GET 405.

**Sources:** Read the reference project's `src/server/mcp/protocol.ts` and hosted route. Checked the [official SDK server guide](https://ts.sdk.modelcontextprotocol.io/server) and the installed 1.30.0 Web Standard transport declarations and implementation.
