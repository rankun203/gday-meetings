import { getAuth, authIssuer } from './config'
export async function discovery(_request: Request, kind: 'oidc' | 'oauth') {
  const auth = await getAuth()
  // Forward the provider's Web Response; serializing it would produce an empty object.
  return auth.handler(
    new Request(
      authIssuer() +
        '/.well-known/' +
        (kind === 'oidc'
          ? 'openid-configuration'
          : 'oauth-authorization-server'),
    ),
  )
}
