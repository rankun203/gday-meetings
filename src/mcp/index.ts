/** Dedicated stdio MCP module. Authentication stays on the server-side API boundary. */
import { config as loadEnv } from 'dotenv'
loadEnv({ quiet: true })
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { z } from 'zod'
const base =
  process.env.GDAY_URL || process.env.SERVER_URL || 'http://localhost:3000'
const token = process.env.GDAY_API_TOKEN
if (!token) throw new Error('GDAY_API_TOKEN is required')
const server = new McpServer({ name: 'gday-meetings', version: '0.1.0' })
server.registerTool(
  'search_meetings',
  {
    description:
      'Search GdayMeetings by meeting title, transcript, or external ID. Returns up to 30 most recently updated matches.',
    inputSchema: { query: z.string().trim().min(1).max(500) },
    annotations: {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false,
    },
  },
  async ({ query }) => {
    try {
      const url = new URL('/api/platform/meetings/search', base)
      url.searchParams.set('query', query)
      const response = await fetch(url, {
        headers: { Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(30_000),
        redirect: 'error',
      })
      if (!response.ok)
        throw new Error(`Meeting search failed (HTTP ${response.status})`)
      const result = await response.json()
      return { content: [{ type: 'text', text: JSON.stringify(result) }] }
    } catch (error) {
      return {
        isError: true,
        content: [
          {
            type: 'text',
            text: error instanceof Error ? error.message : 'Search failed',
          },
        ],
      }
    }
  },
)
await server.connect(new StdioServerTransport())
