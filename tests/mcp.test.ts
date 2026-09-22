import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createServer } from 'node:http'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'

test('MCP exposes exactly one query tool and uses authenticated platform search', async () => {
  const http = createServer((req, res) => {
    assert.equal(req.headers.authorization, 'Bearer test-mcp-key')
    assert.equal(
      new URL(req.url!, 'http://localhost').searchParams.get('query'),
      'roadmap',
    )
    res.setHeader('Content-Type', 'application/json')
    res.end(
      JSON.stringify({ meetings: [{ title: 'Roadmap review' }], total: 1 }),
    )
  })
  await new Promise<void>((resolve) => http.listen(0, '127.0.0.1', resolve))
  const address = http.address() as { port: number }
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ['node_modules/tsx/dist/cli.mjs', 'src/mcp/index.ts'],
    env: {
      PATH: process.env.PATH || '',
      GDAY_URL: `http://127.0.0.1:${address.port}`,
      GDAY_API_TOKEN: 'test-mcp-key',
    },
  })
  const client = new Client({ name: 'integration-test', version: '1.0.0' })
  try {
    await client.connect(transport)
    const tools = await client.listTools()
    assert.deepEqual(
      tools.tools.map((t) => t.name),
      ['search_meetings'],
    )
    const result = await client.callTool({
      name: 'search_meetings',
      arguments: { query: 'roadmap' },
    })
    assert.match(JSON.stringify(result), /Roadmap review/)
  } finally {
    await client.close()
    await new Promise<void>((resolve, reject) =>
      http.close((error) => (error ? reject(error) : resolve())),
    )
  }
})
