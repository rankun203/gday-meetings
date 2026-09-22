import assert from 'node:assert/strict'
import { test } from 'node:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { betterAuth } from 'better-auth'
import { getMigrations } from 'better-auth/db/migration'

// Reopen an existing SQLite identity database, as happens with a persisted Docker volume.
test('SQLite restart accepts stored OAuth arrays, preserves grants and still reports real type drift', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'gday-auth-restart-'))
  Object.assign(process.env, {
    NODE_ENV: 'production',
    SERVER_URL: 'http://localhost:34991',
    DATA_DIR: directory,
    DATABASE_ADAPTER: 'sqlite',
    DATABASE_URI: `file:${directory}/payload.db`,
    PAYLOAD_SECRET: 'test-only-restart-secret-at-least-32-characters',
  })
  const { cms } = await import('../src/server/payload')
  const { createAuthOptions } = await import('../src/server/auth/config')
  const { oauthFixture } = await import('./helpers/oauth')
  const payload = await cms()
  const { issueUserToken } = await oauthFixture(
    payload,
    process.env.SERVER_URL!,
  )
  const identity = await issueUserToken('restart@example.test')
  const options = createAuthOptions()
  const database = options.database as DatabaseSync
  const warnings: string[] = []
  options.logger = {
    level: 'warn',
    log: (level, message) => {
      if (level === 'warn') warnings.push(message)
    },
  }
  try {
    const before = database
      .prepare('SELECT * FROM gday_auth_oauth_clients')
      .all()
    assert.ok(before.length > 0)
    const migration = await getMigrations(options)
    assert.equal(warnings.length, 0, warnings.join('\n'))
    assert.equal(await migration.compileMigrations(), ';')
    await migration.runMigrations()
    assert.deepEqual(
      database.prepare('SELECT * FROM gday_auth_oauth_clients').all(),
      before,
    )

    const restarted = betterAuth(options)
    const refresh = await restarted.handler(
      new Request(process.env.SERVER_URL + '/api/auth/oauth2/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          Origin: process.env.SERVER_URL!,
        },
        body: new URLSearchParams({
          grant_type: 'refresh_token',
          refresh_token: identity.refreshToken,
          client_id: identity.clientId,
          resource: identity.resource,
        }),
      }),
    )
    assert.equal(refresh.status, 200, await refresh.clone().text())
    const tokens = await refresh.json()
    assert.ok(tokens.access_token)
    assert.ok(tokens.scope.split(' ').includes('meetings:read'))
    assert.ok(tokens.scope.split(' ').includes('meetings:write'))

    // A genuine INTEGER-vs-array mismatch must continue to warn.
    database.exec('ALTER TABLE gday_auth_users ADD COLUMN testArray INTEGER')
    options.user!.additionalFields!.testArray = {
      type: 'string[]',
      required: false,
    }
    warnings.length = 0
    await getMigrations(options)
    assert.ok(
      warnings.some(
        (message) =>
          message.includes('testArray') &&
          message.includes('Expected string[] but got INTEGER'),
      ),
    )
    assert.ok(
      !warnings.some((message) =>
        message.includes('Expected string[] but got TEXT'),
      ),
    )
  } finally {
    database.close()
    await payload.destroy()
    await rm(directory, { recursive: true, force: true })
  }
})
