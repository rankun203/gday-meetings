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
docker compose up -d --build
```

The default binds to localhost:3000. Put an HTTPS reverse proxy in front, set `SERVER_URL` to the public origin reachable by workers, and configure the proxy for long audio uploads/downloads and the appropriate maximum body size. Named volume `gday-data` stores SQLite and audio. Back it up together and preserve `PAYLOAD_SECRET`: changing the secret invalidates all existing audio and callback capability URLs. Use a single app replica with SQLite and local audio storage.

Postgres deployment:

```sh
# Add POSTGRES_PASSWORD to .env (URL-safe random value).
docker compose -f compose.yaml -f compose.postgres.yaml up -d --build
```

For an existing Postgres server, set `DATABASE_ADAPTER=postgres` and `DATABASE_URI=postgresql://...` instead. Switching adapters selects a different database; it does not migrate existing content. Audio continues to use the persistent app volume. The committed dialect-specific migrations run on production startup. Back up first when upgrading; coordinate a single migrating instance. Development uses Payload schema push.

For production without Docker, run `pnpm build && pnpm start` with the same environment. SQLite defaults to `data/gday.db`. See [architecture and operations](docs/architecture.md).

## Client and worker contract

See [API reference](docs/api.md). Configure the meeting-notes filedrop URL to this platform origin and its service key to `GDAY_API_TOKEN`. The legacy raw `/upload?filename=...` endpoint is retained. Clients detect durable tasks with authenticated `GET /api/platform/capabilities`; only a 404 means an older filedrop server. A task creation response includes a scoped callback URL/token that can be passed to a worker without sharing the service key.

## MCP

The dedicated `src/mcp` module exposes exactly one tool: **search_meetings**, with a required `query` string. It searches titles, transcript text, and external IDs, returning up to 30 recently updated matches. Run with `pnpm --silent mcp` or configure your MCP client:

```json
{
  "mcpServers": {
    "gday-meetings": {
      "command": "pnpm",
      "args": ["--dir", "/absolute/path/to/gday-meetings", "--silent", "mcp"],
      "env": {
        "GDAY_URL": "https://meetings.example.com",
        "GDAY_API_TOKEN": "your-service-token"
      }
    }
  }
}
```

The stdio module calls the authenticated platform API; it does not need database credentials or direct storage access. Its tool is read-only; the configured service token is privileged and must remain private.

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
