# GdayMeetings

A self-hosted recordings platform built with Payload CMS and Next.js. Audio, processing tasks, and typed outputs live together. Workers persist results before returning to RunPod, so expiring RunPod responses no longer mean lost transcripts.

## Start locally

Requires Node.js 24.15+ and pnpm 12.5.1.

```sh
cp .env.example .env
# Set PAYLOAD_SECRET and GDAY_API_TOKEN to independent random secrets.
pnpm install
pnpm dev
```

Open http://localhost:3000/admin and create your first administrator. SQLite is the default; no database server is needed. Finish first-admin setup on a trusted network before exposing the app publicly. All authenticated CMS users are trusted workspace administrators in this single-workspace release.

The workspace contains **Meetings**, **Tasks**, **Outputs**, and **Audio files**. A meeting groups recording attempts; every task has its own input files and durable output list. `TRANSCRIPT_OUTPUT` bodies retain the complete worker JSON and project track segments into searchable meeting text. Repeat callbacks return the original stored output instead of duplicating it. Audio and outputs have no automatic expiry.

## Deploy

```sh
docker compose pull
docker compose up -d
```

Compose uses the published `ghcr.io/rankun203/gday-meetings:0.2.0` image, available
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

## Client and worker contract

See [API reference](docs/api.md). Configure the meeting-notes filedrop URL to this platform origin and its service key to `GDAY_API_TOKEN`. The legacy raw `/upload?filename=...` endpoint is retained. Clients detect durable tasks with authenticated `GET /api/platform/capabilities`; only a 404 means an older filedrop server. A task creation response includes a scoped callback URL/token that can be passed to a worker without sharing the service key.

## MCP

The hosted **Streamable HTTP** endpoint is `https://meetings.example.com/mcp`. It runs inside the same app/container; MCP clients need only the URL and bearer token, with no local checkout or pnpm process.

Set an independent `GDAY_MCP_TOKEN` on the server for read-only meeting search. When set, this token is accepted only by `/mcp`; it cannot upload files or mutate tasks. If unset, MCP falls back to `GDAY_API_TOKEN` for simple existing deployments. Prefer a dedicated token when sharing access.

Configure a client that supports Streamable HTTP and custom authorization headers (field names can vary by client):

```json
{
  "mcpServers": {
    "gday-meetings": {
      "type": "http",
      "url": "https://meetings.example.com/mcp",
      "headers": {
        "Authorization": "Bearer your-read-only-mcp-token"
      }
    }
  }
}
```

The dedicated `src/mcp` module exposes exactly one tool: **search_meetings**, with a required `query` string. It searches titles, transcript text, and external IDs, returning up to 30 recently updated matches. The endpoint uses stateless JSON responses; GET/SSE and DELETE session operations return 405. OAuth-only clients are not supported yet.

Set `SERVER_URL` to the public app origin. Your reverse proxy must preserve its public `Host` header and the client's `Authorization` header. Requests with an `Origin` header must exactly match `SERVER_URL`'s origin; cross-origin browser calls are not enabled. Normal server-side MCP clients omit `Origin`.

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

## License

MIT.
