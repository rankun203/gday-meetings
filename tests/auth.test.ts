import assert from 'node:assert/strict'
import { test, after } from 'node:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const directory = await mkdtemp(path.join(tmpdir(), 'gday-identity-'))
Object.assign(process.env, {
  NODE_ENV: 'production',
  SERVER_URL: 'http://localhost:34887',
  DATA_DIR: directory,
  DATABASE_ADAPTER: process.env.TEST_POSTGRES_URI ? 'postgres' : 'sqlite',
  DATABASE_URI: process.env.TEST_POSTGRES_URI || `file:${directory}/payload.db`,
  PAYLOAD_SECRET: 'test-only-identity-secret-at-least-32-characters',
})
const { cms } = await import('../src/server/payload')
const { getAuth, getBrowserPrincipal } = await import('../src/server/auth')
const payload = await cms()
const auth = await getAuth()
let ip = 1
async function login(email: string, password = 'correct-password-for-tests') {
  return auth.handler(
    new Request(process.env.SERVER_URL + '/api/auth/sign-in/gday', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        origin: process.env.SERVER_URL!,
        'x-forwarded-for': `192.0.2.${ip++}`,
      },
      body: JSON.stringify({ email, password }),
    }),
  )
}
function session(response: Response) {
  return response.headers
    .getSetCookie()
    .map((x) => x.split(';')[0])
    .join('; ')
}
async function principal(cookie: string) {
  return getBrowserPrincipal(
    new Request(process.env.SERVER_URL!, { headers: { cookie } }),
  )
}
test('canonical login, disabled accounts, no signup and stale identity retirement', async () => {
  const original = await payload.create({
    collection: 'users',
    data: {
      email: 'identity@example.test',
      password: 'correct-password-for-tests',
      role: 'admin',
    },
    overrideAccess: true,
  })
  assert.equal((await login(original.email, 'incorrect')).status, 401)
  const signedIn = await login(original.email)
  assert.equal(signedIn.status, 200, await signedIn.clone().text())
  const cookie = session(signedIn)
  assert.equal((await principal(cookie))?.user.id, original.id)
  const signup = await auth.handler(
    new Request(process.env.SERVER_URL + '/api/auth/sign-up/email', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        origin: process.env.SERVER_URL!,
      },
      body: JSON.stringify({
        name: 'No',
        email: 'no@example.test',
        password: 'correct-password-for-tests',
      }),
    }),
  )
  assert.equal(signup.status, 404)
  await payload.update({
    collection: 'users',
    id: original.id,
    data: { disabled: true },
    overrideAccess: true,
  })
  assert.equal(await principal(cookie), null)
  assert.ok([401, 403].includes((await login(original.email)).status))
  await payload.delete({
    collection: 'users',
    id: original.id,
    overrideAccess: true,
  })
  const replacement = await payload.create({
    collection: 'users',
    data: {
      email: original.email,
      password: 'correct-password-for-tests',
      role: 'member',
    },
    overrideAccess: true,
  })
  const second = await login(replacement.email)
  assert.equal(second.status, 200, await second.clone().text())
  assert.equal((await principal(session(second)))?.user.id, replacement.id)
  assert.equal(await principal(cookie), null)
})
after(async () => {
  await payload.destroy()
  await rm(directory, { recursive: true, force: true })
})

test('signed authorization request resumes through hosted canonical sign-in', async () => {
  const user = await payload.create({
    collection: 'users',
    data: {
      email: 'hosted@example.test',
      password: 'correct-password-for-tests',
      role: 'member',
    },
    overrideAccess: true,
  })
  const origin = process.env.SERVER_URL!
  const call = (pathname: string, body?: unknown) =>
    auth.handler(
      new Request(origin + '/api/auth' + pathname, {
        method: body ? 'POST' : 'GET',
        headers: { origin, 'content-type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
      }),
    )
  const registration = await call('/oauth2/register', {
    application_type: 'native',
    client_name: 'Hosted test',
    redirect_uris: ['http://127.0.0.1:39876/callback'],
    token_endpoint_auth_method: 'none',
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
    scope: 'openid offline_access meetings:read',
  })
  const client = await registration.json()
  assert.equal(registration.status, 201, JSON.stringify(client))
  const params = new URLSearchParams({
    client_id: client.client_id,
    redirect_uri: 'http://127.0.0.1:39876/callback',
    response_type: 'code',
    scope: 'openid offline_access meetings:read',
    resource: origin + '/api/platform',
    code_challenge: 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ',
    code_challenge_method: 'S256',
    state: 'hosted-state',
  })
  const authorize = await call('/oauth2/authorize?' + params)
  const location = new URL(authorize.headers.get('location')!, origin)
  assert.equal(location.pathname, '/sign-in')
  const result = await call('/sign-in/gday', {
    email: user.email,
    password: 'correct-password-for-tests',
    oauth_query: location.search.slice(1),
  })
  const data = await result.json()
  assert.equal(result.status, 200, JSON.stringify(data))
  assert.ok(data.url || data.redirect_uri, JSON.stringify(data))
  assert.equal(
    new URL(data.url || data.redirect_uri, origin).pathname,
    '/consent',
  )
})
