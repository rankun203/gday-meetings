import { wav } from './helpers/audio'
import assert from 'node:assert/strict'
import { after, test } from 'node:test'
import { createServer } from 'node:http'
import { mkdtemp, rm } from 'node:fs/promises'
import path from 'node:path'
import { tmpdir } from 'node:os'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'

const directory = await mkdtemp(path.join(tmpdir(), 'gday-mcp-'))
process.env.DATA_DIR = directory
process.env.DATABASE_ADAPTER = 'sqlite'
process.env.DATABASE_URI = `file:${directory}/test.db`
process.env.PAYLOAD_SECRET = 'test-only-secret-at-least-thirty-two-characters'
process.env.GDAY_API_TOKEN = 'service-test-key'
process.env.GDAY_MCP_TOKEN = 'readonly-mcp-key'
Object.assign(process.env, { NODE_ENV: 'production' })
const { cms } = await import('../src/server/payload')
const payload = await cms()
const { handleMcpRequest } = await import('../src/mcp')
await payload.create({
  collection: 'meetings',
  data: {
    externalId: 'mcp-fixture',
    title: 'Roadmap review',
    transcript: 'Launch planning',
  },
  overrideAccess: true,
})
const http = createServer(async (req, res) => {
  try {
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(Buffer.from(chunk))
    const headers = new Headers()
    for (const [key, value] of Object.entries(req.headers)) {
      if (value !== undefined)
        headers.set(key, Array.isArray(value) ? value.join(', ') : value)
    }
    const request = new Request(`${process.env.SERVER_URL}${req.url}`, {
      method: req.method,
      headers,
      body: chunks.length ? Buffer.concat(chunks) : undefined,
    })
    const response = await handleMcpRequest(request)
    res.writeHead(response.status, Object.fromEntries(response.headers))
    res.end(Buffer.from(await response.arrayBuffer()))
  } catch (error) {
    res.writeHead(500)
    res.end(String(error))
  }
})
await new Promise<void>((resolve) => http.listen(0, '127.0.0.1', resolve))
const address = http.address() as { port: number }
const origin = `http://127.0.0.1:${address.port}`
process.env.SERVER_URL = origin
const url = new URL('/mcp', origin)
const { getAuth } = await import('../src/server/auth')
const auth = await getAuth()
// Exercise multiple identities without waiting on the production login throttle.
// Only this test instance is changed; production options retain rate limiting.
;(await auth.$context).rateLimit.enabled = false
const { oauthFixture } = await import('./helpers/oauth')
const fixture = await oauthFixture(payload, origin)
const authRequest = fixture.authRequest
const issueUserToken = (
  email: string,
  resource = url.href,
  scope = 'mcp:read',
) => fixture.issueUserToken(email, resource, scope)

const authenticated = await issueUserToken('mcp-reader@example.test')
const authorization = `Bearer ${authenticated.token}`
after(async () => {
  await new Promise<void>((resolve, reject) =>
    http.close((error) => (error ? reject(error) : resolve())),
  )
  await payload.destroy()
  await rm(directory, { recursive: true, force: true })
})

test('hosted SDK HTTP initialize, notification, list and search use local private meeting data', async () => {
  const transport = new StreamableHTTPClientTransport(url, {
    requestInit: { headers: { Authorization: authorization } },
  })
  const client = new Client({ name: 'http-integration-test', version: '1.0.0' })
  try {
    await client.connect(transport)
    assert.equal(transport.sessionId, undefined)
    const tools = await client.listTools()
    assert.deepEqual(
      tools.tools.map((tool) => tool.name),
      ['search_meetings'],
    )
    const result = await client.callTool({
      name: 'search_meetings',
      arguments: { query: 'roadmap' },
    })
    assert.equal(result.isError, undefined)
    assert.match(JSON.stringify(result), /Roadmap review/)
    const invalid = await client.callTool({
      name: 'search_meetings',
      arguments: { query: '' },
    })
    assert.equal(invalid.isError, true)
  } finally {
    await client.close()
  }
})

test('MCP rejects unauthenticated, wrong-scope and untrusted-origin requests', async () => {
  const post = (headers: Record<string, string>) =>
    fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }),
    })
  const anonymous = await post({})
  assert.equal(anonymous.status, 401)
  assert.match(anonymous.headers.get('www-authenticate') || '', /^Bearer/)
  for (const token of ['service-test-key', 'readonly-mcp-key']) {
    assert.equal((await post({ Authorization: `Bearer ${token}` })).status, 401)
  }
  assert.equal(
    (
      await post({
        Authorization: authorization,
        Origin: 'https://evil.example',
      })
    ).status,
    403,
  )
  assert.equal(
    (await post({ Authorization: authorization, Origin: 'null' })).status,
    403,
  )
  const deniedHost = await handleMcpRequest(
    new Request('http://evil.example/mcp', {
      method: 'POST',
      headers: { Authorization: authorization },
    }),
  )
  assert.equal(deniedHost.status, 403)
})

test('stateless methods, notification acknowledgement, malformed and oversized bodies', async () => {
  for (const method of ['GET', 'DELETE']) {
    const response = await fetch(url, {
      method,
      headers: { Authorization: authorization },
    })
    assert.equal(response.status, 405)
    assert.equal(response.headers.get('allow'), 'POST')
  }
  const headers = {
    Authorization: authorization,
    Origin: origin,
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
  }
  const notification = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'notifications/initialized',
    }),
  })
  assert.equal(notification.status, 202)
  assert.equal(await notification.text(), '')
  const malformed = await fetch(url, { method: 'POST', headers, body: '{' })
  assert.equal(malformed.status, 400)
  assert.equal((await malformed.json()).error.code, -32700)
  assert.equal(
    (
      await fetch(url, {
        method: 'POST',
        headers,
        body: JSON.stringify({ padding: 'x'.repeat(70_000) }),
      })
    ).status,
    413,
  )
  delete process.env.GDAY_MCP_TOKEN
  try {
    const fallback = await fetch(url, {
      method: 'GET',
      headers: { Authorization: 'Bearer service-test-key' },
    })
    assert.equal(fallback.status, 401)
  } finally {
    process.env.GDAY_MCP_TOKEN = 'readonly-mcp-key'
  }
})

test('signed-out, disabled and deleted-user OAuth access tokens are refused', async () => {
  for (const condition of ['signed-out', 'disabled', 'deleted-user']) {
    const issued = await issueUserToken('mcp-' + condition + '@example.test')
    if (condition === 'deleted-user')
      await payload.delete({
        collection: 'users',
        id: issued.user.id,
        overrideAccess: true,
      })
    else if (condition === 'disabled')
      await payload.update({
        collection: 'users',
        id: issued.user.id,
        data: { disabled: true },
        overrideAccess: true,
      })
    else {
      const revoked = await authRequest('/sign-out', {}, issued.cookie)
      assert.equal(revoked.status, 200, await revoked.clone().text())
    }
    const rejected = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + issued.token,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }),
    })
    assert.equal(
      rejected.status,
      401,
      condition + ' token must not authorize MCP',
    )
  }
})

test('desktop and MCP tokens cannot cross resource audiences', async () => {
  const desktop = await issueUserToken(
    'desktop@example.test',
    origin + '/api/platform',
    'openid profile email meetings:read meetings:write',
  )
  assert.equal(
    (
      await fetch(url, {
        method: 'GET',
        headers: { Authorization: 'Bearer ' + desktop.token },
      })
    ).status,
    401,
  )
  const { requireAccess } = await import('../src/server/auth')
  await assert.rejects(
    requireAccess(
      new Request(origin + '/api/platform/capabilities', {
        headers: { Authorization: authorization },
      }),
      { resource: 'platform', scopes: ['meetings:read'] },
    ),
    /Sign in/,
  )
  const principal = await requireAccess(
    new Request(origin + '/api/platform/capabilities', {
      headers: { Authorization: 'Bearer ' + desktop.token },
    }),
    { resource: 'platform', scopes: ['meetings:write'] },
  )
  assert.equal(principal.user.id, desktop.user.id)
})

test('expired access tokens fail authentication', async (context) => {
  const issued = authenticated
  context.mock.timers.enable({
    apis: ['Date'],
    now: Date.now() + 24 * 60 * 60 * 1000,
  })
  try {
    const response = await handleMcpRequest(
      new Request(url, {
        method: 'GET',
        headers: { Authorization: `Bearer ${issued.token}` },
      }),
    )
    assert.equal(response.status, 401)
  } finally {
    context.mock.timers.reset()
  }
})

test('refresh tokens rotate, reject replay, and can be revoked', async () => {
  const issued = await issueUserToken('refresh@example.test')
  assert.ok(issued.refreshToken)
  const refresh = (token: string) =>
    authRequest(
      '/oauth2/token',
      new URLSearchParams({
        grant_type: 'refresh_token',
        client_id: issued.clientId,
        refresh_token: token,
        resource: issued.resource,
      }),
    )
  const rotated = await refresh(issued.refreshToken)
  assert.equal(rotated.status, 200, await rotated.clone().text())
  const replacement = await rotated.json()
  assert.ok(replacement.refresh_token)
  assert.notEqual(replacement.refresh_token, issued.refreshToken)
  const replay = await refresh(issued.refreshToken)
  assert.equal(replay.status, 400, await replay.clone().text())
  const replayedFamily = await refresh(replacement.refresh_token)
  assert.equal(
    replayedFamily.status,
    400,
    'refresh replay revokes the entire family',
  )
  const fresh = await issueUserToken('revoke-refresh@example.test')
  const revoked = await authRequest(
    '/oauth2/revoke',
    new URLSearchParams({
      token: fresh.refreshToken,
      client_id: fresh.clientId,
      token_type_hint: 'refresh_token',
    }),
  )
  assert.equal(revoked.status, 200, await revoked.clone().text())
  const rejected = await authRequest(
    '/oauth2/token',
    new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: fresh.clientId,
      refresh_token: fresh.refreshToken,
      resource: fresh.resource,
    }),
  )
  assert.equal(rejected.status, 400, await rejected.clone().text())
})

test('discovery aliases return complete standard metadata', async () => {
  const { discovery } = await import('../src/server/auth/discovery')
  for (const kind of ['oidc', 'oauth'] as const) {
    const response = await discovery(
      new Request(origin + '/.well-known/' + kind),
      kind,
    )
    assert.equal(response.status, 200)
    const data = await response.json()
    assert.equal(data.issuer, origin + '/api/auth')
    assert.equal(
      data.authorization_endpoint,
      origin + '/api/auth/oauth2/authorize',
    )
    assert.ok(data.token_endpoint)
    if (kind === 'oidc') assert.ok(data.jwks_uri)
  }
})

test('desktop OAuth uploads and queues a durable task without service credentials', async () => {
  const desktop = await issueUserToken(
    'upload@example.test',
    origin + '/api/platform',
    'openid profile email meetings:read meetings:write',
  )
  const { POST: upload } = await import('../src/app/(site)/upload/route')
  const { POST: createTask, GET: getTask } =
    await import('../src/app/(site)/api/platform/[...path]/route')
  const headers = { Authorization: 'Bearer ' + desktop.token }
  const uploaded = await upload(
    new Request(origin + '/upload?filename=test.wav', {
      method: 'POST',
      headers,
      body: wav(),
    }),
  )
  assert.equal(uploaded.status, 201, await uploaded.clone().text())
  const audio = await uploaded.json()
  assert.equal(
    (
      await upload(
        new Request(origin + '/upload?filename=denied.wav', {
          method: 'POST',
          headers: { Authorization: authorization },
          body: new Uint8Array([1]),
        }),
      )
    ).status,
    401,
  )
  process.env.RUNPOD_ENDPOINT_URL = 'https://api.runpod.ai/v2/test-only'
  process.env.RUNPOD_API_KEY = 'test-only-never-used'
  try {
    const body = {
      externalId: 'desktop-upload',
      title: 'Uploaded via user login',
      idempotencyKey: 'test-attempt',
      inputs: [
        {
          url: new URL(audio.url, origin).href,
          trackName: 'mic',
          sourceType: 'mic',
          channels: 1,
        },
      ],
    }
    const request = () =>
      new Request(origin + '/api/platform/tasks', {
        method: 'POST',
        headers: { ...headers, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
    const ctx = { params: Promise.resolve({ path: ['tasks'] }) }
    const created = await createTask(request(), ctx)
    assert.equal(created.status, 201, await created.clone().text())
    const task = await created.json()
    assert.equal(task.executionState, 'QUEUED')
    assert.equal(task.resultSink, undefined)
    const repeated = await createTask(request(), ctx)
    assert.equal((await repeated.json()).id, task.id)
    const result = await getTask(
      new Request(origin + '/api/platform/tasks/' + task.id, { headers }),
      { params: Promise.resolve({ path: ['tasks', task.id] }) },
    )
    assert.equal(result.status, 200)
    assert.deepEqual((await result.json()).outputs, [])
  } finally {
    delete process.env.RUNPOD_ENDPOINT_URL
    delete process.env.RUNPOD_API_KEY
  }
})
