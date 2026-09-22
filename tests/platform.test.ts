import { wav } from './helpers/audio'
import assert from 'node:assert/strict'
import { after, test } from 'node:test'
import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const directory = await mkdtemp(path.join(tmpdir(), 'gday-test-'))
process.env.DATA_DIR = directory
process.env.PAYLOAD_SECRET = 'test-only-secret-at-least-thirty-two-characters'
// A former shared-key value must never grant access.
process.env.GDAY_API_TOKEN = 'test-service-token'
process.env.SERVER_URL = 'http://localhost:3000'
Object.assign(process.env, { NODE_ENV: 'production' })
if (process.env.DATABASE_ADAPTER !== 'postgres')
  process.env.DATABASE_URI = `file:${directory}/test.db`
const { cms } = await import('../src/server/payload')
const payload = await cms()
const { GET, POST, PATCH } =
  await import('../src/app/(site)/api/platform/[...path]/route')
const { POST: upload } = await import('../src/app/(site)/upload/route')
const { GET: download } = await import('../src/app/(site)/files/[key]/route')
const { transcriptText } = await import('../src/server/tasks')
const { oauthFixture } = await import('./helpers/oauth')
const { issueUserToken } = await oauthFixture(payload, process.env.SERVER_URL)
const identity = await issueUserToken('platform-test@example.test')
const { capability } = await import('../src/server/security')
async function seedTask(input: {
  externalId: string
  title: string
  inputs: never[]
}) {
  const found = await payload.find({
    collection: 'meetings',
    where: { externalId: { equals: input.externalId } },
    limit: 1,
    overrideAccess: true,
  })
  const meeting =
    found.docs[0] ||
    (await payload.create({
      collection: 'meetings',
      data: { externalId: input.externalId, title: input.title },
      overrideAccess: true,
    }))
  const task = await payload.create({
    collection: 'tasks',
    data: { meeting: meeting.id, status: 'PENDING', inputs: [] },
    overrideAccess: true,
  })
  return {
    id: task.id,
    resultSink: {
      url: `http://localhost:3000/api/platform/tasks/${task.id}/outputs`,
      token: capability('result', task.id),
    },
  }
}
after(async () => {
  await payload.destroy()
  await rm(directory, { recursive: true, force: true })
})
const request = (
  method: string,
  url: string,
  body?: unknown,
  token = identity.token,
) =>
  new Request(`http://localhost:3000${url}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
const context = (...parts: string[]) => ({
  params: Promise.resolve({ path: parts }),
})

test('durable tasks preserve worker output, isolate capabilities, support retries, and search track transcripts', async () => {
  assert.equal(
    (
      await GET(
        request('GET', '/api/platform/capabilities', undefined, 'wrong'),
        context('capabilities'),
      )
    ).status,
    401,
  )
  assert.deepEqual(
    await (
      await GET(
        request('GET', '/api/platform/capabilities'),
        context('capabilities'),
      )
    ).json(),
    {
      durableTasks: true,
      meetingImports: true,
      transcription: false,
      version: 2,
    },
  )
  const task = await seedTask({
    externalId: 'integration-session',
    title: 'Planning meeting',
    inputs: [],
  })
  const second = await seedTask({
    externalId: 'integration-session',
    title: 'Planning meeting',
    inputs: [],
  })
  assert.notEqual(task.id, second.id)
  const before = await (
    await GET(
      request('GET', `/api/platform/tasks/${task.id}`),
      context('tasks', task.id),
    )
  ).json()
  assert.deepEqual(before.outputs, [])
  const body = {
    tracks: {
      mic: { segments: [{ start: 2, end: 3, text: 'Budget approved' }] },
      system: { segments: [{ start: 0, end: 1, text: 'Roadmap discussion' }] },
    },
    language: 'en',
    model: 'test',
  }
  assert.equal(transcriptText(body), 'Roadmap discussion\nBudget approved')
  const wrapped = { type: 'TRANSCRIPT_OUTPUT', body }
  assert.equal(
    (
      await POST(
        request(
          'POST',
          task.resultSink.url.replace('http://localhost:3000', ''),
          wrapped,
          second.resultSink.token,
        ),
        context('tasks', task.id, 'outputs'),
      )
    ).status,
    401,
  )
  for (let i = 0; i < 2; i++)
    assert.equal(
      (
        await POST(
          request(
            'POST',
            task.resultSink.url.replace('http://localhost:3000', ''),
            wrapped,
            task.resultSink.token,
          ),
          context('tasks', task.id, 'outputs'),
        )
      ).status,
      200,
    )
  const after = await (
    await GET(
      request('GET', `/api/platform/tasks/${task.id}`),
      context('tasks', task.id),
    )
  ).json()
  assert.equal(after.status, 'COMPLETED')
  assert.equal(after.outputs.length, 1)
  assert.deepEqual(after.outputs[0].body, body)
  const result = await GET(
    request(
      'GET',
      `/api/platform/tasks/${task.id}/outputs/${after.outputs[0].id}`,
    ),
    context('tasks', task.id, 'outputs', after.outputs[0].id),
  )
  assert.deepEqual(await result.json(), body)
  assert.match(result.headers.get('Content-Disposition') || '', /attachment/)
  const search = await (
    await GET(
      request('GET', '/api/platform/meetings/search?query=Budget'),
      context('meetings', 'search'),
    )
  ).json()
  assert.equal(search.meetings.length, 1)
  assert.match(search.meetings[0].transcript, /Budget approved/)
  const patch = await PATCH(
    request('PATCH', `/api/platform/tasks/${task.id}`, {
      status: 'FAILED',
      error: 'late poll failure',
    }),
    context('tasks', task.id),
  )
  assert.equal(patch.status, 405)
  await assert.rejects(
    payload.find({ collection: 'meetings', overrideAccess: false }),
    { status: 403 },
  )
})

test('audio uploads are complete before exposure and support authenticated byte ranges', async () => {
  const bytes = wav()
  const uploaded = await upload(
    new Request('http://localhost:3000/upload?filename=sample.wav', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${identity.token}`,
        'Content-Type': 'audio/wav',
      },
      body: bytes,
    }),
  )
  assert.equal(uploaded.status, 201)
  const { url } = await uploaded.json()
  const key = new URL(url, 'http://localhost:3000').pathname.split('/').pop()!
  const ctx = { params: Promise.resolve({ key }) }
  assert.equal(
    (await download(new Request(`http://localhost:3000/files/${key}`), ctx))
      .status,
    401,
  )
  const full = await download(new Request(`http://localhost:3000${url}`), ctx)
  assert.equal(full.headers.get('Content-Length'), String(bytes.length))
  assert.deepEqual(Buffer.from(await full.arrayBuffer()), bytes)
  const part = await download(
    new Request(`http://localhost:3000${url}`, {
      headers: { Range: 'bytes=4-8' },
    }),
    ctx,
  )
  assert.equal(part.status, 206)
  assert.deepEqual(Buffer.from(await part.arrayBuffer()), bytes.subarray(4, 9))
  assert.equal(part.headers.get('Content-Range'), `bytes 4-8/${bytes.length}`)
  const invalid = await download(
    new Request(`http://localhost:3000${url}`, {
      headers: { Range: 'bytes=100-' },
    }),
    ctx,
  )
  assert.equal(invalid.status, 416)
  const record = await payload.find({
    collection: 'audio-files',
    where: { storageKey: { equals: key } },
    limit: 1,
    overrideAccess: true,
  })
  await payload.delete({
    collection: 'audio-files',
    id: record.docs[0].id,
    overrideAccess: true,
  })
  assert.equal(
    (await download(new Request(`http://localhost:3000${url}`), ctx)).status,
    404,
  )
  await assert.rejects(stat(path.join(directory, 'audio', key)), {
    code: 'ENOENT',
  })
})

test('newer empty transcript clears previous text; out-of-order callbacks and late failures cannot undo it', async () => {
  const { persistOutput } = await import('../src/server/tasks')
  const { patchTask } = await import('../src/server/atomic')
  const old = await seedTask({
    externalId: 'race-test-' + Date.now(),
    title: 'Race test',
    inputs: [],
  })
  const original = await payload.findByID({
    collection: 'tasks',
    id: old.id,
    overrideAccess: true,
  })
  const meetingId =
    typeof original.meeting === 'object' ? original.meeting.externalId : ''
  const newer = await seedTask({
    externalId: meetingId,
    title: 'Race test',
    inputs: [],
  })
  await payload.update({
    collection: 'tasks',
    id: old.id,
    data: { createdAt: '2020-01-01T00:00:00.000Z' },
    overrideAccess: true,
  })
  await persistOutput(payload, old.id, {
    type: 'TRANSCRIPT_OUTPUT',
    body: { transcript: 'Obsolete words' },
  })
  await persistOutput(payload, newer.id, {
    type: 'TRANSCRIPT_OUTPUT',
    body: { tracks: { mic: { segments: [] } } },
  })
  await Promise.all([
    persistOutput(payload, old.id, {
      type: 'TRANSCRIPT_OUTPUT',
      body: { transcript: 'Obsolete words' },
    }),
    patchTask(payload, newer.id, {
      status: 'FAILED',
      error: 'Late polling error',
    }),
  ])
  const final = await payload.findByID({
    collection: 'tasks',
    id: newer.id,
    overrideAccess: true,
  })
  assert.equal(final.status, 'COMPLETED')
  assert.equal(
    typeof final.meeting === 'object' ? final.meeting.transcript : undefined,
    '',
  )
})

test('concurrent callbacks keep the newest attempt transcript', async () => {
  const { persistOutput } = await import('../src/server/tasks')
  const externalId = 'concurrent-' + Date.now()
  const older = await seedTask({
    externalId,
    title: 'Concurrent',
    inputs: [],
  })
  const newer = await seedTask({
    externalId,
    title: 'Concurrent',
    inputs: [],
  })
  await payload.update({
    collection: 'tasks',
    id: older.id,
    data: { createdAt: '2020-01-01T00:00:00.000Z' },
    overrideAccess: true,
  })
  await Promise.all([
    persistOutput(payload, newer.id, {
      type: 'TRANSCRIPT_OUTPUT',
      body: { transcript: 'Current transcript' },
    }),
    persistOutput(payload, older.id, {
      type: 'TRANSCRIPT_OUTPUT',
      body: { transcript: 'Outdated transcript' },
    }),
  ])
  const task = await payload.findByID({
    collection: 'tasks',
    id: newer.id,
    overrideAccess: true,
  })
  assert.equal(
    typeof task.meeting === 'object' ? task.meeting.transcript : undefined,
    'Current transcript',
  )
})

test('former shared keys cannot upload, read meetings, or create client-run tasks', async () => {
  for (const route of ['capabilities', 'meetings/search']) {
    const response = await GET(
      request('GET', '/api/platform/' + route, undefined, 'test-service-token'),
      context(...route.split('/')),
    )
    assert.equal(response.status, 401)
  }
  const denied = await POST(
    request(
      'POST',
      '/api/platform/tasks',
      {
        externalId: 'forbidden',
        title: 'Forbidden',
        inputs: [],
        idempotencyKey: 'attempt',
      },
      'test-service-token',
    ),
    context('tasks'),
  )
  assert.equal(denied.status, 401)
  const audio = await upload(
    new Request('http://localhost:3000/upload?filename=denied.wav', {
      method: 'POST',
      headers: { Authorization: 'Bearer test-service-token' },
      body: 'audio',
    }),
  )
  assert.equal(audio.status, 401)
  const legacy = await POST(
    request('POST', '/api/platform/tasks', {
      externalId: 'forbidden',
      title: 'Forbidden',
      inputs: [],
      idempotencyKey: 'attempt',
      execute: false,
    }),
    context('tasks'),
  )
  assert.equal(legacy.status, 400)
  const unsupported = await POST(
    request('POST', '/api/platform/tasks', {
      externalId: 'unconfigured',
      title: 'Unconfigured',
      inputs: [{ url: 'http://localhost:3000/files/test.wav?token=test' }],
      idempotencyKey: 'attempt',
    }),
    context('tasks'),
  )
  assert.equal(unsupported.status, 503)
})

test('CMS uploads own their file and metadata, reject metadata-only records and replacement', async () => {
  const { createLocalReq } = await import('payload')
  const { readFile, readdir } = await import('node:fs/promises')
  const req = await createLocalReq(
    { user: { ...identity.user, collection: 'users' } },
    payload,
  )
  const bytes = wav()
  const record = await payload.create({
    collection: 'audio-files',
    overrideAccess: false,
    req,
    data: {
      storageKey: '../../forged.wav',
      originalName: 'forged',
      size: 999,
      contentType: 'text/html',
    },
    file: {
      name: 'meeting.wav',
      mimetype: 'audio/wav',
      size: bytes.length,
      data: bytes,
    },
  })
  assert.match(record.filename!, /^[0-9a-f-]{36}\.wav$/)
  assert.equal(record.storageKey, record.filename)
  assert.equal(record.originalName, 'meeting.wav')
  assert.equal(record.filesize, bytes.length)
  assert.equal(record.size, bytes.length)
  assert.equal(record.mimeType, record.contentType)
  assert.deepEqual(
    await readFile(path.join(directory, 'audio', record.filename!)),
    bytes,
  )
  await assert.rejects(
    payload.create({
      collection: 'audio-files',
      data: {} as never,
      overrideAccess: false,
      req,
    }),
    { status: 400 },
  )
  await assert.rejects(
    payload.update({
      collection: 'audio-files',
      id: record.id,
      data: {},
      overrideAccess: false,
      req,
      file: {
        name: 'replacement.wav',
        mimetype: 'audio/wav',
        size: bytes.length,
        data: bytes,
      },
    }),
    { status: 400 },
  )
  const updated = await payload.update({
    collection: 'audio-files',
    id: record.id,
    data: { storageKey: '../../forged.wav', filename: 'forged.wav', size: 999 },
    overrideAccess: false,
    req,
  })
  assert.equal(updated.filename, record.filename)
  assert.equal(updated.storageKey, record.storageKey)
  assert.equal(updated.size, bytes.length)
  await payload.delete({
    collection: 'audio-files',
    id: record.id,
    overrideAccess: false,
    req,
  })
  await assert.rejects(stat(path.join(directory, 'audio', record.filename!)), {
    code: 'ENOENT',
  })
  assert.equal(
    (await readdir(path.join(directory, 'audio'))).some((name) =>
      name.endsWith('.partial'),
    ),
    false,
  )
})

test('existing recordings migrate into CMS file management without moving bytes', async () => {
  const { randomUUID } = await import('node:crypto')
  const { writeFile, readFile } = await import('node:fs/promises')
  const { sql } = await import('@payloadcms/db-postgres')
  const postgres = payload.db.name !== 'sqlite'
  const migration = postgres
    ? await import('../src/migrations-postgres/20260922_051634_managed_audio')
    : await import('../src/migrations-sqlite/20260922_051618_managed_audio')
  const db = (payload.db as any).drizzle
  await migration.down({ db } as never)
  const id = randomUUID(),
    key = randomUUID() + '.wav',
    bytes = wav()
  await writeFile(path.join(directory, 'audio', key), bytes)
  const insert = sql`INSERT INTO audio_files (id, storage_key, original_name, size, content_type, created_at, updated_at)
    VALUES (${id}, ${key}, 'existing.wav', ${bytes.length}, 'audio/wav', ${new Date().toISOString()}, ${new Date().toISOString()})`
  if (postgres) await db.execute(insert)
  else await db.run(insert)
  await migration.up({ db } as never)
  const record = await payload.findByID({
    collection: 'audio-files',
    id,
    overrideAccess: true,
  })
  assert.equal(record.filename, key)
  assert.equal(record.filesize, bytes.length)
  assert.equal(record.mimeType, 'audio/wav')
  assert.deepEqual(await readFile(path.join(directory, 'audio', key)), bytes)
  const response = await download(
    new Request(
      `http://localhost:3000/files/${key}?token=${capability('audio', key)}`,
    ),
    { params: Promise.resolve({ key }) },
  )
  assert.equal(response.status, 200)
  await response.arrayBuffer()
  await payload.delete({ collection: 'audio-files', id, overrideAccess: true })
  await assert.rejects(stat(path.join(directory, 'audio', key)), {
    code: 'ENOENT',
  })
})

test('CMS and desktop uploads enforce the same size cap and clean rejected temporary files', async () => {
  const { createLocalReq } = await import('payload')
  const { readdir } = await import('node:fs/promises')
  const { prepareAudio } = await import('../src/server/audio-hooks')
  const req = await createLocalReq(
    { user: { ...identity.user, collection: 'users' } },
    payload,
  )
  const oversized = {
    name: 'large.wav',
    mimetype: 'audio/wav',
    size: 500_000_001,
    data: Buffer.alloc(0),
  }
  req.file = oversized
  assert.throws(
    () => prepareAudio({ args: {}, operation: 'create', req } as never),
    { status: 413 },
  )
  req.file = { ...oversized, size: 500_000_000 }
  assert.doesNotThrow(() =>
    prepareAudio({ args: {}, operation: 'create', req } as never),
  )
  const old = process.env.MAX_UPLOAD_BYTES
  try {
    process.env.MAX_UPLOAD_BYTES = '8'
    const response = await upload(
      new Request('http://localhost:3000/upload?filename=large.wav', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${identity.token}`,
          'Content-Type': 'audio/wav',
        },
        body: wav(),
      }),
    )
    assert.equal(response.status, 413)
    await assert.rejects(
      payload.create({
        collection: 'audio-files',
        data: {} as never,
        overrideAccess: false,
        req,
        file: {
          name: 'large.wav',
          mimetype: 'audio/wav',
          size: wav().length,
          data: wav(),
        },
      }),
      { status: 413 },
    )
    assert.equal(
      (await readdir(path.join(directory, 'audio'))).some((name) =>
        name.endsWith('.partial'),
      ),
      false,
    )
  } finally {
    if (old === undefined) delete process.env.MAX_UPLOAD_BYTES
    else process.env.MAX_UPLOAD_BYTES = old
  }
})
