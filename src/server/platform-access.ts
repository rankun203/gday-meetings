import type { PayloadRequest } from 'payload'
import { requireAccess } from './auth'
import { HttpError, serviceAuthorized } from './security'

/** The worker service and delegated user API are separate authorization paths. */
export async function platformAccess(
  request: Request,
  scope: 'meetings:read' | 'meetings:write',
): Promise<PayloadRequest | undefined> {
  if (serviceAuthorized(request)) return undefined
  const principal = await requireAccess(request, {
    resource: 'platform',
    scopes: [scope],
  })
  return principal.req
}
export function requireWorkerService(request: Request) {
  if (!serviceAuthorized(request))
    throw new HttpError(
      403,
      'This operation requires the worker service credential',
    )
}
