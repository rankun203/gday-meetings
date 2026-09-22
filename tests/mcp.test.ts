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
const authorization = 'Bearer readonly-mcp-key'
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
  assert.equal(
    (await post({ Authorization: 'Bearer service-test-key' })).status,
    401,
  )
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
  const { serviceAuthorized } = await import('../src/server/security')
  assert.equal(
    serviceAuthorized(
      new Request(url, { headers: { Authorization: authorization } }),
    ),
    false,
  )
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
    assert.equal(fallback.status, 405)
  } finally {
    process.env.GDAY_MCP_TOKEN = 'readonly-mcp-key'
  }
})
