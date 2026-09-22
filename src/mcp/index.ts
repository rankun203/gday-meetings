import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js'
import { z } from 'zod'
import packageJSON from '../../package.json' with { type: 'json' }
import { equal, HttpError, readJSON } from '../server/security'

function rpcError(
  status: number,
  message: string,
  headers?: HeadersInit,
  code = -32000,
) {
  return Response.json(
    { jsonrpc: '2.0', id: null, error: { code, message } },
    { status, headers: { 'Cache-Control': 'no-store', ...headers } },
  )
}

/** Explicit configuration, never forwarded headers, defines the trusted origin. */
function trustedRequest(request: Request) {
  const configured = new URL(process.env.SERVER_URL || 'http://localhost:3000')
  const host = request.headers.get('host') || new URL(request.url).host
  if (host.toLowerCase() !== configured.host.toLowerCase()) return false
  const origin = request.headers.get('origin')
  return origin === null || origin === configured.origin
}

async function searchStoredMeetings(query: string) {
  const [{ cms }, { searchMeetings }] = await Promise.all([
    import('../server/payload'),
    import('../server/tasks'),
  ])
  // This explicit system read follows MCP token validation and exposes only search.
  return searchMeetings(await cms(), query)
}

/** A fresh server per request: no process-local sessions or SSE connection state. */
export async function handleMcpRequest(request: Request): Promise<Response> {
  if (!trustedRequest(request)) return rpcError(403, 'Untrusted host or origin')
  const token = process.env.GDAY_MCP_TOKEN || process.env.GDAY_API_TOKEN
  if (
    !token ||
    !equal(request.headers.get('authorization') || '', `Bearer ${token}`)
  ) {
    return rpcError(401, 'Bearer authentication required', {
      'WWW-Authenticate': 'Bearer realm="GdayMeetings MCP"',
    })
  }
  if (request.method !== 'POST') {
    return new Response(null, {
      status: 405,
      headers: { Allow: 'POST', 'Cache-Control': 'no-store' },
    })
  }
  const server = new McpServer({
    name: 'gday-meetings',
    version: packageJSON.version,
  })
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
        const result = await searchStoredMeetings(query)
        return { content: [{ type: 'text', text: JSON.stringify(result) }] }
      } catch (error) {
        console.error('MCP meeting search failed', error)
        return {
          isError: true,
          content: [
            { type: 'text', text: 'Meeting search failed. Try again.' },
          ],
        }
      }
    },
  )
  const transport = new WebStandardStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  })
  try {
    await server.connect(transport)
    const parsedBody = await readJSON(request, 64 * 1024)
    const response = await transport.handleRequest(request, { parsedBody })
    response.headers.set('Cache-Control', 'no-store')
    return response
  } catch (error) {
    if (error instanceof HttpError)
      return rpcError(
        error.status,
        error.message,
        undefined,
        error.status === 400 ? -32700 : -32000,
      )
    console.error('MCP request failed', error)
    return rpcError(500, 'Internal server error')
  } finally {
    await server.close()
  }
}
