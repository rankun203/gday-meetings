import assert from 'node:assert/strict'
import { test } from 'node:test'
import { serverEnv } from '../src/lib/env'
const base = { PAYLOAD_SECRET: 'test-secret-at-least-thirty-two-characters' }
test('RunPod environment must be paired and cannot leak secrets in validation errors', () => {
  assert.equal(serverEnv(base).RUNPOD_API_KEY, undefined)
  const key = 'sensitive-test-value'
  for (const input of [
    { RUNPOD_API_KEY: key },
    { RUNPOD_ENDPOINT_URL: 'https://api.runpod.ai/v2/test' },
    {
      RUNPOD_ENDPOINT_URL: 'http://api.runpod.ai/v2/test',
      RUNPOD_API_KEY: key,
    },
    {
      RUNPOD_ENDPOINT_URL: 'https://user:password@api.runpod.ai/v2/test',
      RUNPOD_API_KEY: key,
    },
  ]) {
    assert.throws(
      () => serverEnv({ ...base, ...input }),
      (error) =>
        error instanceof Error &&
        error.message.includes('RUNPOD_ENDPOINT_URL') &&
        !error.message.includes(key) &&
        !error.message.includes('password@'),
    )
  }
  assert.equal(
    serverEnv({
      ...base,
      RUNPOD_ENDPOINT_URL: 'https://api.runpod.ai/v2/test',
      RUNPOD_API_KEY: key,
    }).RUNPOD_API_KEY,
    key,
  )
})
test('database and upstream provider environment is validated centrally', () => {
  assert.throws(
    () => serverEnv({ ...base, DATABASE_ADAPTER: 'postgres' }),
    /DATABASE_URI/,
  )
  assert.throws(
    () =>
      serverEnv({ ...base, OIDC_UPSTREAM_ISSUER: 'https://identity.example' }),
    /OIDC_UPSTREAM/,
  )
  assert.throws(
    () => serverEnv({ ...base, DATABASE_URI: 'postgresql://localhost/test' }),
    /SQLite/,
  )
})

test('upload size defaults to 500 MB and may only be lowered', () => {
  assert.equal(serverEnv(base).MAX_UPLOAD_BYTES, 500_000_000)
  assert.equal(
    serverEnv({ ...base, MAX_UPLOAD_BYTES: '1000000' }).MAX_UPLOAD_BYTES,
    1_000_000,
  )
  for (const value of ['500000001', '0', '-1'])
    assert.throws(
      () => serverEnv({ ...base, MAX_UPLOAD_BYTES: value }),
      /MAX_UPLOAD_BYTES/,
    )
})
