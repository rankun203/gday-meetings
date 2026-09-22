import { createLocalReq, type PayloadRequest } from 'payload'
import type { User } from '../../payload-types'
import { HttpError } from '../security'
import { cms } from '../payload'
import {
  getAuth,
  authIssuer,
  authOrigin,
  resourceURL,
  canonicalUser,
} from './config'
export { getAuth, authIssuer }
export interface Principal {
  user: User
  req: PayloadRequest
  scopes: ReadonlySet<string>
}
export interface IdentityAdapter {
  getBrowserPrincipal(request: Request): Promise<Principal | null>
  authenticateAccess(
    request: Request,
    resource: 'platform' | 'mcp',
  ): Promise<Principal | null>
}
export function protectedResourceMetadata(
  resource: 'platform' | 'mcp' = 'mcp',
) {
  return {
    resource: resourceURL(resource),
    authorization_servers: [authIssuer()],
    scopes_supported:
      resource === 'mcp' ? ['mcp:read'] : ['meetings:read', 'meetings:write'],
    bearer_methods_supported: ['header'],
  }
}
async function principal(
  id: string,
  request: Request,
  scopes: Iterable<string>,
): Promise<Principal | null> {
  const user = await canonicalUser(id)
  if (!user) return null
  const req = await createLocalReq(
    {
      user: { ...user, collection: 'users' },
      req: { headers: request.headers, url: request.url },
    },
    await cms(),
  )
  return { user, req, scopes: new Set(scopes) }
}
export async function getBrowserPrincipal(
  request: Request,
): Promise<Principal | null> {
  const auth = await getAuth()
  const session = await auth.api.getSession({ headers: request.headers })
  const id = (session?.user as { payloadUserId?: string } | undefined)
    ?.payloadUserId
  return id ? principal(id, request, []) : null
}
export async function authenticateAccess(
  request: Request,
  resource: 'platform' | 'mcp',
): Promise<Principal | null> {
  if (!request.headers.get('authorization')?.startsWith('Bearer ')) return null
  const auth = await getAuth()
  const response = await auth.handler(
    new Request(authIssuer() + '/gday/verify-access', {
      method: 'POST',
      headers: {
        Authorization: request.headers.get('authorization')!,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ resource }),
    }),
  )
  if (!response.ok) return null
  const claims = (await response.json()) as { userId: string; scope: string }
  return principal(
    claims.userId,
    request,
    claims.scope.split(' ').filter(Boolean),
  )
}
export const identityAdapter: IdentityAdapter = {
  getBrowserPrincipal,
  authenticateAccess,
}
export async function requireAccess(
  request: Request,
  options: { resource: 'platform' | 'mcp'; scopes: string[] },
): Promise<Principal> {
  const result = await authenticateAccess(request, options.resource)
  const challenge = `Bearer resource_metadata="${authOrigin()}/.well-known/oauth-protected-resource/${options.resource === 'mcp' ? 'mcp' : 'api/platform'}"`
  if (!result)
    throw new HttpError(401, 'Sign in to GdayMeetings', {
      'WWW-Authenticate': challenge,
    })
  if (options.scopes.some((scope) => !result.scopes.has(scope)))
    throw new HttpError(403, 'Insufficient permissions', {
      'WWW-Authenticate':
        challenge +
        ', error="insufficient_scope", scope="' +
        options.scopes.join(' ') +
        '"',
    })
  return result
}
