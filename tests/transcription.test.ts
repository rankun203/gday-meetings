import { wav } from './helpers/audio'
import assert from 'node:assert/strict'
import { after, test } from 'node:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { createLocalReq } from 'payload'

const directory = await mkdtemp(path.join(tmpdir(), 'gday-execution-'))
process.env.DATA_DIR = directory
process.env.PAYLOAD_SECRET =
  'execution-test-secret-at-least-thirty-two-characters'
process.env.SERVER_URL = 'https://meetings.example.test'
process.env.RUNPOD_ENDPOINT_URL =
  'https://api.runpod.example.test/v2/extraction'
process.env.RUNPOD_API_KEY = 'provider-secret'
Object.assign(process.env, { NODE_ENV: 'production' })
if (process.env.DATABASE_ADAPTER !== 'postgres')
  process.env.DATABASE_URI = `file:${directory}/test.db`
const { cms } = await import('../src/server/payload')
const payload = await cms()
const { createTask, getTask, persistOutput, taskInput } =
  await import('../src/server/tasks')
const { advanceTranscription, validateOwnedAudio } =
  await import('../src/server/transcription')
const { capability } = await import('../src/server/security')
after(async () => {
  await payload.destroy()
  await rm(directory, { recursive: true, force: true })
})
const output = { tracks: {}, language: 'en', model: 'test' }
const audio = await payload.create({
  collection: 'audio-files',
  data: {} as never,
  file: {
    name: 'recording.wav',
    data: wav(),
    size: wav().length,
    mimetype: 'audio/wav',
  },
  overrideAccess: true,
})
const audioKey = audio.storageKey
const inputs = [
  {
    url: `${process.env.SERVER_URL}/files/${audioKey}?token=${capability('audio', audioKey)}`,
    trackName: 'mic',
    sourceType: 'mic',
    channels: 1,
  },
]
await payload.create({
  collection: 'users',
  data: {
    email: 'bootstrap@example.test',
    password: 'test-passphrase-12345',
    role: 'admin',
  },
  overrideAccess: true,
})
const member = await payload.create({
  collection: 'users',
  data: {
    email: 'member@example.test',
    password: 'test-passphrase-12345',
    role: 'member',
  },
  overrideAccess: true,
})
const memberRequest = () =>
  createLocalReq({ user: { ...member, collection: 'users' } }, payload)
const newTask = async () =>
  createTask(
    payload,
    {
      externalId: randomUUID(),
      title: 'Execution test',
      inputs,
      idempotencyKey: randomUUID(),
      executionOptions: { language: 'en', diarize: true },
    },
    await memberRequest(),
  )

test('persisted output repairs interrupted completion without another provider request', async () => {
  const task = await newTask()
  await payload.create({
    collection: 'outputs',
    data: {
      key: `${task.id}:TRANSCRIPT_OUTPUT`,
      task: task.id,
      type: 'TRANSCRIPT_OUTPUT',
      body: output,
    },
    overrideAccess: true,
  })
  await advanceTranscription(payload, task.id, {
    fetch: fakeFetch(async () => {
      assert.fail('provider request after durable result')
    }),
  })
  assert.equal((await getTask(payload, task.id)).status, 'COMPLETED')
})
const fakeFetch = (
  fn: (url: string, init?: RequestInit) => Promise<Response>,
) => fn as typeof fetch

test('members cannot forge raw tasks or outputs but validated submissions work', async () => {
  const req = await memberRequest()
  const meeting = await payload.create({
    collection: 'meetings',
    data: { externalId: randomUUID(), title: 'Member meeting' },
    overrideAccess: true,
  })
  await assert.rejects(
    payload.create({
      collection: 'tasks',
      data: {
        meeting: meeting.id,
        status: 'PENDING',
        executionState: 'SUBMITTED',
        runpodJobId: 'unrelated-provider-job',
      },
      req,
      overrideAccess: false,
    }),
    { status: 403 },
  )
  const queued = await createTask(
    payload,
    {
      externalId: meeting.externalId,
      title: meeting.title,
      inputs,
      idempotencyKey: 'member-attempt',
    },
    req,
  )
  assert.equal(queued.executionState, 'QUEUED')
  await assert.rejects(
    payload.create({
      collection: 'outputs',
      data: {
        key: `${queued.id}:TRANSCRIPT_OUTPUT`,
        task: queued.id,
        type: 'TRANSCRIPT_OUTPUT',
        body: output,
      },
      req,
      overrideAccess: false,
    }),
    { status: 403 },
  )
  await payload.update({
    collection: 'tasks',
    id: queued.id,
    data: { executionState: 'SUBMITTED', runpodJobId: 'forged' },
    req,
    overrideAccess: false,
  })
  const unchanged = await getTask(payload, queued.id)
  assert.equal(unchanged.executionState, 'QUEUED')
  assert.equal(unchanged.runpodJobId, null)
})

test('idempotent enqueue validates owned audio and keeps callback secret server-side', async () => {
  const input = {
    externalId: randomUUID(),
    title: 'Meeting',
    inputs,
    idempotencyKey: 'one',
  }
  const first = await createTask(payload, input, await memberRequest())
  const retry = await createTask(payload, input, await memberRequest())
  assert.equal(first.id, retry.id)
  assert.equal(first.executionState, 'QUEUED')
  assert.equal('resultSink' in first, false)
  await assert.rejects(
    createTask(
      payload,
      { ...input, title: 'different' },
      await memberRequest(),
    ),
    {
      status: 409,
    },
  )
  assert.throws(() =>
    validateOwnedAudio([{ url: 'http://169.254.169.254/latest/meta-data' }]),
  )
  assert.throws(() =>
    validateOwnedAudio([
      { ...inputs[0], url: inputs[0].url.replace(/token=.*/, 'token=wrong') },
    ]),
  )
  assert.equal(
    taskInput.safeParse({ ...input, idempotencyKey: undefined }).success,
    false,
  )
  assert.equal(taskInput.safeParse({ ...input, execute: false }).success, false)
  assert.equal(taskInput.safeParse({ ...input, execute: true }).success, false)
})

test('concurrent durable claims submit once with exact worker contract and recover completed output', async () => {
  const task = await newTask()
  let submissions = 0
  const fetcher = fakeFetch(async (url, init) => {
    if (url.endsWith('/run')) {
      submissions++
      assert.equal(
        init?.headers && (init.headers as Record<string, string>).Authorization,
        'Bearer provider-secret',
      )
      const body = JSON.parse(String(init?.body))
      assert.deepEqual(body.input.tracks, [
        {
          audio_url: inputs[0].url,
          track_name: 'mic',
          source_type: 'mic',
          channels: 1,
        },
      ])
      assert.equal(body.input.language, 'en')
      assert.equal(body.input.diarize, true)
      assert.equal(body.input.result_sink.token, capability('result', task.id))
      assert.equal(
        body.input.result_sink.url,
        `${process.env.SERVER_URL}/api/platform/tasks/${task.id}/outputs`,
      )
      return Response.json({ id: 'job-one' })
    }
    return Response.json({ status: 'COMPLETED', output })
  })
  const now = Date.now()
  const results = await Promise.allSettled([
    advanceTranscription(payload, task.id, { fetch: fetcher, now }),
    advanceTranscription(payload, task.id, { fetch: fetcher, now }),
  ])
  // SQLite may reject a losing writer as busy, which the periodic scan retries.
  assert.equal(
    results.filter((result) => result.status === 'fulfilled').length >= 1,
    true,
  )
  assert.equal(submissions, 1)
  assert.equal((await getTask(payload, task.id)).runpodJobId, 'job-one')
  await advanceTranscription(payload, task.id, {
    fetch: fetcher,
    now: now + 20_000,
  })
  assert.equal((await getTask(payload, task.id)).status, 'COMPLETED')
  assert.deepEqual((await getTask(payload, task.id)).outputs[0].body, output)
})

test('lost submission acknowledgement and stale restart claims never auto-submit twice', async () => {
  const task = await newTask()
  let calls = 0
  const fetcher = fakeFetch(async () => {
    calls++
    throw new TypeError('connection interrupted')
  })
  await advanceTranscription(payload, task.id, { fetch: fetcher })
  assert.equal(
    (await getTask(payload, task.id)).executionState,
    'SUBMISSION_UNKNOWN',
  )
  await advanceTranscription(payload, task.id, { fetch: fetcher })
  assert.equal(calls, 1)
  await persistOutput(payload, task.id, {
    type: 'TRANSCRIPT_OUTPUT',
    body: output,
  })
  assert.equal((await getTask(payload, task.id)).status, 'COMPLETED')
  const stale = await newTask()
  await payload.update({
    collection: 'tasks',
    id: stale.id,
    data: {
      executionState: 'SUBMITTING',
      submissionStartedAt: new Date(Date.now() - 180_000).toISOString(),
    },
    overrideAccess: true,
  })
  await advanceTranscription(payload, stale.id, { fetch: fetcher })
  assert.equal(
    (await getTask(payload, stale.id)).executionState,
    'SUBMISSION_UNKNOWN',
  )
  assert.equal(calls, 1)
})

test('transient status errors remain recoverable and callbacks win terminal failure races', async () => {
  const task = await newTask()
  const now = Date.now()
  await advanceTranscription(payload, task.id, {
    now,
    fetch: fakeFetch(async () => Response.json({ id: 'job' })),
  })
  await advanceTranscription(payload, task.id, {
    now: now + 20_000,
    fetch: fakeFetch(async () => new Response(null, { status: 503 })),
  })
  assert.equal((await getTask(payload, task.id)).status, 'PENDING')
  await advanceTranscription(payload, task.id, {
    now: now + 40_000,
    fetch: fakeFetch(async () => {
      await persistOutput(payload, task.id, {
        type: 'TRANSCRIPT_OUTPUT',
        body: output,
      })
      return Response.json({ status: 'FAILED' })
    }),
  })
  assert.equal((await getTask(payload, task.id)).status, 'COMPLETED')
  const failed = await newTask()
  await advanceTranscription(payload, failed.id, {
    now,
    fetch: fakeFetch(async () => Response.json({ id: 'failed-job' })),
  })
  await advanceTranscription(payload, failed.id, {
    now: now + 20_000,
    fetch: fakeFetch(async () => Response.json({ status: 'TIMED_OUT' })),
  })
  assert.equal((await getTask(payload, failed.id)).status, 'FAILED')
  await persistOutput(payload, failed.id, {
    type: 'TRANSCRIPT_OUTPUT',
    body: output,
  })
  assert.equal((await getTask(payload, failed.id)).status, 'COMPLETED')
})
