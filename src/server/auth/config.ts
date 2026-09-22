import { mkdirSync } from 'node:fs'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { Pool } from 'pg'
import {
  betterAuth,
  type BetterAuthOptions,
  type BetterAuthPlugin,
} from 'better-auth'
import { createAuthEndpoint, APIError } from 'better-auth/api'
import { setSessionCookie } from 'better-auth/cookies'
import { genericOAuth, jwt } from 'better-auth/plugins'
import { getMigrations } from 'better-auth/db/migration'
import {
  oauthProvider,
  getOAuthProviderApi,
  type OAuthOptions,
} from '@better-auth/oauth-provider'
import { z } from 'zod'
import { cms } from '../payload'
import { serverEnv } from '../../lib/env'

export const authOrigin = () => new URL(serverEnv().SERVER_URL).origin
export const authIssuer = () => authOrigin() + '/api/auth'
export const resourceURL = (resource: 'platform' | 'mcp') =>
  authOrigin() + (resource === 'mcp' ? '/mcp' : '/api/platform')
export async function canonicalUser(id: string) {
  const payload = await cms()
  const result = await payload.find({
    collection: 'users',
    where: { id: { equals: id } },
    limit: 1,
    depth: 0,
    overrideAccess: true,
  })
  const user = result.docs[0]
  return user &&
    !user.disabled &&
    (!user.lockUntil || Date.parse(user.lockUntil) <= Date.now())
    ? user
    : null
}
const scopes = [
  'openid',
  'profile',
  'email',
  'offline_access',
  'mcp:read',
  'meetings:read',
  'meetings:write',
]
export function createAuthOptions(): BetterAuthOptions {
  const env = serverEnv()
  const dataDir = env.DATA_DIR
  mkdirSync(dataDir, { recursive: true })
  const database =
    env.DATABASE_ADAPTER === 'postgres'
      ? new Pool({
          connectionString: env.AUTH_DATABASE_URI || env.DATABASE_URI,
        })
      : new DatabaseSync(
          (env.AUTH_DATABASE_URI || path.join(dataDir, 'auth.db')).replace(
            /^file:/,
            '',
          ),
        )
  const providerOptions: OAuthOptions<string[]> = {
    loginPage: '/sign-in',
    consentPage: '/consent',
    scopes,
    grantTypes: ['authorization_code', 'refresh_token'],
    allowDynamicClientRegistration: true,
    allowUnauthenticatedClientRegistration: true,
    resources: [
      {
        identifier: resourceURL('mcp'),
        name: 'Meeting search',
        allowedScopes: [
          'openid',
          'profile',
          'email',
          'offline_access',
          'mcp:read',
        ],
      },
      {
        identifier: resourceURL('platform'),
        name: 'Meeting recordings',
        allowedScopes: [
          'openid',
          'profile',
          'email',
          'offline_access',
          'meetings:read',
          'meetings:write',
        ],
      },
    ],
    resourceSeedMode: 'overwrite',
    clientRegistrationDefaultResources: [
      resourceURL('mcp'),
      resourceURL('platform'),
    ],
    accessTokenExpiresIn: 300,
    customAccessTokenClaims: ({ user }) => ({
      gday_user_id: user?.payloadUserId,
    }),
    schema: {
      oauthClient: { modelName: 'gday_auth_oauth_clients' },
      oauthResource: { modelName: 'gday_auth_oauth_resources' },
      oauthClientResource: { modelName: 'gday_auth_oauth_client_resources' },
      oauthRefreshToken: { modelName: 'gday_auth_oauth_refresh_tokens' },
      oauthAccessToken: { modelName: 'gday_auth_oauth_access_tokens' },
      oauthConsent: { modelName: 'gday_auth_oauth_consents' },
      oauthClientAssertion: { modelName: 'gday_auth_oauth_client_assertions' },
    },
  }
  const bridge = {
    id: 'gday-canonical-users',
    endpoints: {
      signInGday: createAuthEndpoint(
        '/sign-in/gday',
        {
          method: 'POST',
          body: z.object({
            email: z.string().email(),
            password: z.string().min(1).max(4096),
            oauth_query: z.string().max(16384).optional(),
          }),
        },
        async (ctx) => {
          const payload = await cms()
          let login
          try {
            login = await payload.login({
              collection: 'users',
              data: { email: ctx.body.email, password: ctx.body.password },
            })
          } catch {
            throw new APIError('UNAUTHORIZED', {
              message: 'Invalid email or password',
            })
          }
          const canonical = login.user
            ? await canonicalUser(login.user.id)
            : null
          if (!canonical)
            throw new APIError('FORBIDDEN', {
              message: 'This account is disabled',
            })
          type ShadowUser = {
            id: string
            name: string
            email: string
            emailVerified: boolean
            createdAt: Date
            updatedAt: Date
            payloadUserId: string
          }
          let user = await ctx.context.adapter.findOne<ShadowUser>({
            model: 'user',
            where: [{ field: 'payloadUserId', value: canonical.id }],
          })
          // Email identifies the login form, never the OAuth account. Retire stale
          // shadows before reusing an address; their grants cannot follow a new user.
          const collision = await ctx.context.adapter.findOne<ShadowUser>({
            model: 'user',
            where: [{ field: 'email', value: canonical.email }],
          })
          if (collision && collision.payloadUserId !== canonical.id) {
            const owner = await canonicalUser(collision.payloadUserId)
            if (owner?.email === canonical.email)
              throw new APIError('CONFLICT', {
                message: 'Identity address conflict',
              })
            await ctx.context.internalAdapter.deleteUser(collision.id)
          }
          if (!user)
            user = (await ctx.context.internalAdapter.createUser(
              {
                id: canonical.id,
                name: canonical.email,
                email: canonical.email,
                emailVerified: false,
                payloadUserId: canonical.id,
              },
              { method: 'gday-canonical' },
            )) as ShadowUser
          if (!user)
            throw new APIError('INTERNAL_SERVER_ERROR', {
              message: 'Unable to create identity session',
            })
          if (user.email !== canonical.email)
            user = (await ctx.context.internalAdapter.updateUser(user.id, {
              email: canonical.email,
              name: canonical.email,
            })) as typeof user
          const session = await ctx.context.internalAdapter.createSession(
            user!.id,
          )
          if (!session)
            throw new APIError('INTERNAL_SERVER_ERROR', {
              message: 'Unable to sign in',
            })
          await setSessionCookie(ctx, { session, user: user! })
          // The same canonical login also opens Payload Admin for administrators.
          if (login.token)
            ctx.setCookie('payload-token', login.token, {
              httpOnly: true,
              secure: authOrigin().startsWith('https:'),
              sameSite: 'lax',
              path: '/',
              maxAge: 7200,
            })
          return ctx.json({
            user: { id: canonical.id, email: canonical.email },
            redirect: false,
          })
        },
      ),
      verifyGdayAccess: createAuthEndpoint(
        '/gday/verify-access',
        {
          method: 'POST',
          body: z.object({ resource: z.enum(['platform', 'mcp']) }),
        },
        async (ctx) => {
          const header = ctx.headers?.get('authorization') || ''
          if (!header.startsWith('Bearer '))
            throw new APIError('UNAUTHORIZED', {
              message: 'Bearer token required',
            })
          const claims = await getOAuthProviderApi(
            ctx,
            providerOptions,
          ).requireActiveAccessToken(header.slice(7))
          const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud]
          if (
            claims.iss !== authIssuer() ||
            !audience.includes(resourceURL(ctx.body.resource)) ||
            claims.cnf
          )
            throw new APIError('UNAUTHORIZED', {
              message: 'Token is not valid for this resource',
            })
          if (
            typeof claims.gday_user_id !== 'string' ||
            !(await canonicalUser(claims.gday_user_id))
          )
            throw new APIError('UNAUTHORIZED', {
              message: 'Account is no longer active',
            })
          return ctx.json({
            userId: claims.gday_user_id,
            scope: typeof claims.scope === 'string' ? claims.scope : '',
          })
        },
      ),
    },
  } satisfies BetterAuthPlugin
  const plugins: BetterAuthPlugin[] = [
    jwt({
      jwt: { issuer: authIssuer() },
      schema: { jwks: { modelName: 'gday_auth_jwks' } },
    }),
    oauthProvider(providerOptions),
    bridge,
  ]
  if (
    env.OIDC_UPSTREAM_ISSUER &&
    env.OIDC_UPSTREAM_CLIENT_ID &&
    env.OIDC_UPSTREAM_CLIENT_SECRET
  ) {
    plugins.push(
      genericOAuth({
        config: [
          {
            providerId: 'upstream',
            discoveryUrl:
              env.OIDC_UPSTREAM_ISSUER.replace(/\/$/, '') +
              '/.well-known/openid-configuration',
            clientId: env.OIDC_UPSTREAM_CLIENT_ID,
            clientSecret: env.OIDC_UPSTREAM_CLIENT_SECRET,
            scopes: ['openid', 'profile', 'email'],
            pkce: true,
            disableSignUp: true,
            disableImplicitSignUp: true,
          },
        ],
      }),
    )
  }
  return {
    appName: 'GdayMeetings',
    baseURL: authOrigin(),
    basePath: '/api/auth',
    secret: env.PAYLOAD_SECRET,
    database,
    trustedOrigins: [authOrigin()],
    disabledPaths: [
      '/sign-up/email',
      '/sign-in/email',
      '/update-user',
      '/delete-user',
      '/change-email',
      '/change-password',
      '/set-password',
      '/token',
    ],
    user: {
      modelName: 'gday_auth_users',
      additionalFields: {
        payloadUserId: {
          type: 'string',
          required: true,
          unique: true,
          input: false,
        },
      },
    },
    session: {
      modelName: 'gday_auth_sessions',
      cookieCache: { enabled: false },
    },
    account: {
      modelName: 'gday_auth_accounts',
      accountLinking: { enabled: true, disableImplicitLinking: true },
    },
    verification: { modelName: 'gday_auth_verifications' },
    advanced: { database: { generateId: 'uuid' } },
    databaseHooks: {
      session: {
        create: {
          before: async (session) => {
            const adapterUser = await (
              await getAuth()
            ).$context.then((ctx) =>
              ctx.adapter.findOne<{ payloadUserId: string }>({
                model: 'user',
                where: [{ field: 'id', value: session.userId }],
              }),
            )
            if (
              !adapterUser ||
              !(await canonicalUser(adapterUser.payloadUserId))
            )
              return false
            return { data: session }
          },
        },
      },
    },
    plugins,
  }
}
let instance: ReturnType<typeof betterAuth> | undefined
let pending: Promise<ReturnType<typeof betterAuth>> | undefined
export async function getAuth() {
  if (instance) return instance
  if (!pending)
    pending = (async () => {
      const options = createAuthOptions()
      const migration = await getMigrations(options)
      await migration.runMigrations()
      instance = betterAuth(options)
      return instance
    })().catch((error) => {
      pending = undefined
      throw error
    })
  return pending
}
