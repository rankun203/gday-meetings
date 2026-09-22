import { config as loadEnv } from 'dotenv'
import path from 'node:path'
import { z } from 'zod'
loadEnv({ quiet: true })

const optional = z.preprocess(
  (value) => (value === '' ? undefined : value),
  z.string().min(1).optional(),
)
const schema = z
  .object({
    PAYLOAD_SECRET: z.string().min(32),
    SERVER_URL: z.url().default('http://localhost:3000'),
    DATA_DIR: z.string().min(1).default(path.resolve('data')),
    DATABASE_ADAPTER: z.enum(['sqlite', 'postgres']).default('sqlite'),
    DATABASE_URI: optional,
    AUTH_DATABASE_URI: optional,
    RUNPOD_ENDPOINT_URL: optional,
    RUNPOD_API_KEY: optional,
    OIDC_UPSTREAM_ISSUER: optional,
    OIDC_UPSTREAM_CLIENT_ID: optional,
    OIDC_UPSTREAM_CLIENT_SECRET: optional,
    MAX_UPLOAD_BYTES: z.coerce
      .number()
      .int()
      .positive()
      .default(2 * 1024 ** 3),
  })
  .superRefine((value, ctx) => {
    if (Boolean(value.RUNPOD_ENDPOINT_URL) !== Boolean(value.RUNPOD_API_KEY)) {
      ctx.addIssue({
        code: 'custom',
        path: ['RUNPOD_ENDPOINT_URL'],
        message:
          'Configure RUNPOD_ENDPOINT_URL and RUNPOD_API_KEY together, or leave both unset',
      })
    }
    if (value.RUNPOD_ENDPOINT_URL) {
      let url: URL | undefined
      try {
        url = new URL(value.RUNPOD_ENDPOINT_URL)
      } catch {
        /* reported below */
      }
      if (
        !url ||
        url.protocol !== 'https:' ||
        url.username ||
        url.password ||
        url.search ||
        url.hash
      )
        ctx.addIssue({
          code: 'custom',
          path: ['RUNPOD_ENDPOINT_URL'],
          message:
            'Must be an HTTPS endpoint without credentials, query, or fragment',
        })
    }
    const upstream = [
      value.OIDC_UPSTREAM_ISSUER,
      value.OIDC_UPSTREAM_CLIENT_ID,
      value.OIDC_UPSTREAM_CLIENT_SECRET,
    ]
    if (upstream.some(Boolean) && !upstream.every(Boolean))
      ctx.addIssue({
        code: 'custom',
        path: ['OIDC_UPSTREAM_ISSUER'],
        message: 'Configure all three OIDC_UPSTREAM variables together',
      })
    if (
      value.DATABASE_ADAPTER === 'postgres' &&
      !value.DATABASE_URI?.match(/^postgres(?:ql)?:\/\//)
    )
      ctx.addIssue({
        code: 'custom',
        path: ['DATABASE_URI'],
        message:
          'Postgres requires a postgres:// or postgresql:// connection URI',
      })
    if (
      value.DATABASE_ADAPTER === 'sqlite' &&
      value.DATABASE_URI &&
      !value.DATABASE_URI.startsWith('file:')
    )
      ctx.addIssue({
        code: 'custom',
        path: ['DATABASE_URI'],
        message: 'SQLite requires a file: URI',
      })
  })

/** Server-only configuration; no secret is exposed through NEXT_PUBLIC variables. */
export function serverEnv(
  source: Record<string, string | undefined> = process.env,
) {
  const result = schema.safeParse(source)
  if (!result.success) {
    // Never include raw environment values (including credentials) in errors/logs.
    throw new Error(
      'Invalid server configuration: ' +
        result.error.issues
          .map((issue) => issue.path.join('.') + ': ' + issue.message)
          .join('; '),
    )
  }
  return result.data
}
