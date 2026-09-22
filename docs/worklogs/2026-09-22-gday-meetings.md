---
date: 2026-09-22
task: GdayMeetings recordings platform
status: complete
---

## Recordings platform and durable results

**Problem:** Filedrop only retained audio; short-lived RunPod result responses could disappear before the client downloaded them. The user also needed an administrative workspace and meeting search.

**Implemented solution:** One Payload CMS / Next.js app with meetings, UUID task attempts, input audio, immutable typed outputs, full JSON downloads, a scoped result callback, and transcript search. Streaming file uploads preserve the existing filedrop contract, publish only complete files, and support byte ranges. Authenticated CMS deletion revokes audio capability access and deletes the file. A dedicated stdio MCP module exposes only `search_meetings`.

**Reasoning:** Store outputs as related rows with a unique task/type key, exposing the requested outputs array through the API and CMS join. This gives durable callback deduplication without an append race. Write the result before derived state, allowing retry to repair projections. Atomic updates compare the transcript version on the meeting row itself and prevent late polling errors from downgrading completed tasks. The complete original result survives regardless of the searchable projection.

**Technical debt:** Local audio disk storage deliberately targets one application instance. Horizontal scaling requires an object/shared storage adapter. The initial MCP tool uses a privileged service token, although its only exposed action is read-only; introduce scoped API credentials before granting MCP access to less-trusted clients. Search uses substring matching, sufficient for the initial single tool; add indexed full-text ranking when meeting volume requires it. SQLite callback writes serialize per Payload instance to accommodate libsql’s shared connection; bounded busy retries handle transient contention. Reassess this queue when moving to a different SQLite driver or distributed service. Stable HMAC capabilities are revoked by audio deletion or global secret rotation, not individual token rotation; add per-record token versioning if independent revocation becomes necessary. No automatic retention policy exists; add explicit lifecycle controls before automated deletion.

## Databases and deployment

**Problem:** The platform needed a zero-server default, optional Postgres, and a reproducible public deployment.

**Implemented solution:** SQLite defaults to a persistent local data directory. Postgres selects the alternate Payload adapter from environment configuration. Both use UUID IDs, generated types, committed initial and transcript-version migrations, and automatic production migration execution. Docker builds the standalone app, runs as a non-root user, and persists data with Compose; a second Compose file adds Postgres.

**Reasoning:** Follow the reference project's single-root Payload architecture without copying its study domain or credentials. Pin current packages from the npm registry: Payload 3.90.1, Next 16.3.5, React 19.3.0, pnpm 12.5.1. GraphQL remains on Payload's supported 16.x peer range, rather than incompatible latest 17.x. Database selection does not imply cross-database content migration.

**Technical debt:** Production migration startup assumes one migrating instance; use a dedicated migration release step before multiple replicas. Payload 3.90.1's Postgres adapter retains a reconnect pool client and `payload.destroy()` does not close that connection; tests use Node's `--test-force-exit` after all assertions/cleanup, without private pool internals. Revisit when upstream implements shutdown. Conditional SQL for task/projection state is a deliberate adapter boundary because Payload updateMany reads before updating; both dialects have integration coverage and must stay covered when schema naming changes.

## Validation

**Results:** TypeScript and production Next build passed. Fresh production SQLite and Postgres migrations passed. Integration tests exercise task creation, callback capability isolation, idempotent persistence, full downloads, track transcript search, private collection access, streaming audio/ranges, deletion revocation, empty transcript replacement, out-of-order results, concurrent callbacks, and late status changes. MCP is exercised through actual SDK initialization, tool listing, and authenticated search invocation.

**Deployment results:** Docker image built successfully. Independent production HTTP smoke passed: homepage/admin 200; unauthenticated capabilities 401; real Python worker audio downloads and result callbacks twice; one durable output, completed state, and searchable transcript. Final source was rebuilt after the concurrency fixes. No real recordings, user data, or credentials were copied into the repository.

**Sources checked:** npm registry latest/version manifests for every direct package; Payload [installation](https://payloadcms.com/docs/getting-started/installation), [SQLite](https://payloadcms.com/docs/database/sqlite), [Postgres](https://payloadcms.com/docs/database/postgres), and [migrations](https://payloadcms.com/docs/database/migrations); installed Next.js route-handler documentation.
