import assert from 'node:assert/strict'
import { createHash, randomBytes } from 'node:crypto'
import type { Payload } from 'payload'
import { getAuth } from '../../src/server/auth'
export async function oauthFixture(payload: Payload, origin: string) {
  const auth = await getAuth()
  async function authRequest(path: string, body?: unknown, cookie?: string) {
    return auth.handler(
      new Request(origin + '/api/auth' + path, {
        method: body === undefined ? 'GET' : 'POST',
        headers: {
          Origin: origin,
          ...(cookie ? { Cookie: cookie } : {}),
          ...(body instanceof URLSearchParams
            ? { 'Content-Type': 'application/x-www-form-urlencoded' }
            : body === undefined
              ? {}
              : { 'Content-Type': 'application/json' }),
        },
        body:
          body === undefined
            ? undefined
            : body instanceof URLSearchParams
              ? body
              : JSON.stringify(body),
      }),
    )
  }
  async function issueUserToken(
    email: string,
    resource = origin + '/api/platform',
    scope = 'meetings:read meetings:write',
  ) {
    const password = 'test-user-password-very-long'
    const user = await payload.create({
      collection: 'users',
      data: { email, password, role: 'member' },
      overrideAccess: true,
    })
    const login = await authRequest('/sign-in/gday', { email, password })
    assert.equal(login.status, 200, await login.clone().text())
    const cookie = login.headers
      .getSetCookie()
      .map((value) => value.split(';')[0])
      .join('; ')
    assert.ok(cookie)
    const redirect = 'http://127.0.0.1:39876/callback'
    const registered = await authRequest('/oauth2/register', {
      application_type: 'native',
      client_name: 'Gday integration test',
      redirect_uris: [redirect],
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      token_endpoint_auth_method: 'none',
      scope: scope + ' offline_access',
    })
    assert.equal(registered.status, 201, await registered.clone().text())
    const client = await registered.json()
    const verifier = randomBytes(32).toString('base64url')
    const params = new URLSearchParams({
      client_id: client.client_id,
      redirect_uri: redirect,
      response_type: 'code',
      scope: scope + ' offline_access',
      state: 'test-state',
      code_challenge: createHash('sha256').update(verifier).digest('base64url'),
      code_challenge_method: 'S256',
      resource,
    })
    const authorization = await authRequest(
      '/oauth2/authorize?' + params,
      undefined,
      cookie,
    )
    assert.equal(authorization.status, 302, await authorization.clone().text())
    const consentURL = new URL(authorization.headers.get('location')!, origin)
    assert.equal(
      consentURL.pathname,
      '/consent',
      consentURL.searchParams.get('error_description') ||
        consentURL.searchParams.get('error') ||
        'Unexpected callback',
    )
    const consent = await authRequest(
      '/oauth2/consent',
      { accept: true, oauth_query: consentURL.search.slice(1) },
      cookie,
    )
    assert.equal(consent.status, 200, await consent.clone().text())
    const accepted = await consent.json()
    const callback = new URL(accepted.redirect_uri || accepted.url)
    assert.equal(callback.searchParams.get('state'), 'test-state')
    const code = callback.searchParams.get('code')
    assert.ok(code)
    const exchanged = await authRequest(
      '/oauth2/token',
      new URLSearchParams({
        grant_type: 'authorization_code',
        client_id: client.client_id,
        code,
        redirect_uri: redirect,
        code_verifier: verifier,
        resource,
      }),
    )
    assert.equal(exchanged.status, 200, await exchanged.clone().text())
    const tokens = await exchanged.json()
    assert.equal(tokens.token_type.toLowerCase(), 'bearer')
    assert.ok(tokens.access_token)
    if (scope.split(' ').includes('openid'))
      assert.ok(tokens.id_token, 'OIDC clients receive a signed ID token')
    return {
      user,
      token: tokens.access_token as string,
      clientId: client.client_id as string,
      cookie,
      refreshToken: tokens.refresh_token as string,
      resource,
    }
  }

  return { issueUserToken, authRequest }
}
