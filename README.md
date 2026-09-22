# GdayMeetings

A self-hosted recordings platform built with Payload CMS and Next.js. Audio, processing tasks, and typed outputs live together. Workers persist results before returning to RunPod, so expiring RunPod responses no longer mean lost transcripts.

## Start locally

Requires Node.js 24.15+ and pnpm 12.5.1.

```sh
cp .env.example .env
# Set PAYLOAD_SECRET to a stable random secret of at least 32 characters.
pnpm install
pnpm dev
```

Open http://localhost:3000/admin and create your first administrator. SQLite is the default; no database server is needed. Finish first-admin setup on a trusted network before exposing the app publicly. GdayMeetings is the source of user management. Administrators manage accounts in Payload; members can work with recordings in the shared workspace. Existing accounts retain their previous administrator access when upgrading.

The workspace contains **Meetings**, **Tasks**, **Outputs**, and **Audio files**. A meeting groups recording attempts; every task has its own input files and durable output list. `TRANSCRIPT_OUTPUT` bodies retain the complete worker JSON and project track segments into searchable meeting text. Repeat callbacks return the original stored output instead of duplicating it. Audio and outputs have no automatic expiry.

## Deploy

```sh
docker compose pull
docker compose up -d
```

Compose uses the published `ghcr.io/rankun203/gday-meetings:0.3.3` image, available
for Linux AMD64 and ARM64. Set `GDAY_VERSION` to select another published version.
For a source build, use `docker compose -f compose.yaml -f compose.build.yaml up -d --build`.

The default binds to localhost:3000. Put an HTTPS reverse proxy in front, set `SERVER_URL` to the public origin reachable by workers, and configure the proxy for long audio uploads/downloads and the appropriate maximum body size. Named volume `gday-data` stores SQLite and audio. Back it up together and preserve `PAYLOAD_SECRET`: changing the secret invalidates all existing audio and callback capability URLs. Use a single app replica with SQLite and local audio storage.

Postgres deployment:

```sh
# Add POSTGRES_PASSWORD to .env (URL-safe random value).
docker compose -f compose.yaml -f compose.postgres.yaml up -d
```

For an existing Postgres server, set `DATABASE_ADAPTER=postgres` and `DATABASE_URI=postgresql://...` instead. Switching adapters selects a different database; it does not migrate existing content. Audio continues to use the persistent app volume. The committed dialect-specific migrations run on production startup. Back up first when upgrading; coordinate a single migrating instance. Development uses Payload schema push.

For production without Docker, run `pnpm build && pnpm start` with the same environment. SQLite defaults to `data/gday.db`. See [architecture and operations](docs/architecture.md).

Releases are published by pushing a `vX.Y.Z` tag matching `package.json`, with
notes in `.github/release-notes/vX.Y.Z.md`. The workflow validates source, publishes
the multi-platform image under `X.Y.Z` and `latest`, and creates the GitHub release.
To retry publication of an existing tag without changing it, run
`gh workflow run release.yml --ref master -f tag=vX.Y.Z`.

## Client and worker contract

See [API reference](docs/api.md). Configure the meeting-notes client with this platform origin and sign in through GdayMeetings. User OAuth tokens authorize uploads and task submissions. Every task requires a stable `idempotencyKey`; Gday queues and executes it using server-side `RUNPOD_ENDPOINT_URL` and `RUNPOD_API_KEY`. Callback capabilities stay between Gday and the worker. Clients poll durable task outputs and download the transcript when ready.

## MCP

The hosted **Streamable HTTP** endpoint is `https://meetings.example.com/mcp`. It runs inside the app/container. Connect with an OAuth-capable MCP client using this URL; no local process, shared MCP secret, or custom Authorization header is needed.

The client discovers authorization, registers, opens your GdayMeetings login, and asks you to allow meeting search. Only tokens issued after an authenticated workspace user grants consent can call MCP. The single `mcp:read` permission allows searching and reading workspace meetings; members share the workspace, while user management is restricted to administrators.

`search_meetings` takes a required `query` string and searches titles, transcript text, and external IDs, returning up to 30 recently updated matches. Search runs with the authorizing user's Payload access rules.

Authorization uses S256 PKCE, short-lived one-use codes, five-minute access tokens, and rotating refresh tokens with replay protection. Gday uses the maintained Better Auth OAuth/OIDC provider and canonical Payload accounts. Discovery is served at `/.well-known/oauth-protected-resource/mcp` and `/.well-known/oauth-authorization-server`; clients discover token and revocation endpoints from metadata. See [MCP authorization](docs/mcp.md).

All client access uses user OAuth. Deployment-wide API/MCP keys and client-managed transcription submission are not supported.

Set `SERVER_URL` to the public HTTPS app origin (HTTP is for local development). Your reverse proxy must preserve the public `Host` and client's `Authorization` header. Requests with an `Origin` header must match the configured origin; cross-origin browser calls are not enabled. The transport is stateless: POST carries MCP requests; GET/SSE and DELETE return 405 after authentication.

## Development

```sh
pnpm typecheck
pnpm test
pnpm build
pnpm generate:types
# Schema changes require migrations for BOTH profiles:
pnpm payload migrate:create meaningful_name
DATABASE_ADAPTER=postgres DATABASE_URI=postgresql://... pnpm payload migrate:create meaningful_name
```

Tests create an isolated SQLite database by default and exercise actual production migrations, task callbacks, auth boundaries, audio ranges, and search. For Postgres use a disposable database: `DATABASE_ADAPTER=postgres DATABASE_URI=postgresql://... pnpm test`. Never run integration tests against a real workspace.

Audio Files accepts recordings up to 500 MB (500,000,000 bytes). Prefer Opus, M4A or MP3; WAV remains supported. It is a native Payload upload collection: select or drag in a recording and save. The CMS stores the file under `DATA_DIR/audio`, generates metadata, and deletes the file when its record is deleted. Desktop uploads use the same collection. Existing recordings migrate in place.


## License

MIT.
