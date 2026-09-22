import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js'
import { z } from 'zod'
import packageJSON from '../../package.json' with { type: 'json' }
import { HttpError, readJSON } from '../server/security'

import { cms } from '../server/payload'
import { searchMeetings } from '../server/tasks'
import { authenticateAccess, authIssuer } from '../server/auth'

function bearerChallenge(error: string) {
  const base = new URL(authIssuer()).origin
  return `Bearer error="${error}", resource_metadata="${base}/.well-known/oauth-protected-resource/mcp", scope="mcp:read"`
}

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

/** A fresh server per request: no process-local sessions or SSE connection state. */
export async function handleMcpRequest(request: Request): Promise<Response> {
  if (!trustedRequest(request)) return rpcError(403, 'Untrusted host or origin')
  const payload = await cms()
  const principal = await authenticateAccess(request, 'mcp')
  if (!principal) {
    return rpcError(401, 'User authorization required', {
      'WWW-Authenticate': bearerChallenge('invalid_token'),
    })
  }
  if (!principal.scopes.has('mcp:read')) {
    return rpcError(403, 'Meeting search permission required', {
      'WWW-Authenticate': bearerChallenge('insufficient_scope'),
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
        const result = await searchMeetings(payload, query, principal.req)
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
