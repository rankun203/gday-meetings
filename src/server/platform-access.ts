import type { PayloadRequest } from 'payload'
import { requireAccess } from './auth'

/** User operations require a scoped OAuth access token. */
export async function platformAccess(
  request: Request,
  scope: 'meetings:read' | 'meetings:write',
): Promise<PayloadRequest> {
  const principal = await requireAccess(request, {
    resource: 'platform',
    scopes: [scope],
  })
  return principal.req
}
