import assert from 'node:assert/strict'
import { after, test } from 'node:test'
import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const directory = await mkdtemp(path.join(tmpdir(), 'gday-test-'))
process.env.DATA_DIR = directory
process.env.PAYLOAD_SECRET = 'test-only-secret-at-least-thirty-two-characters'
process.env.GDAY_API_TOKEN = 'test-service-token'
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
after(async () => {
  await payload.destroy()
  await rm(directory, { recursive: true, force: true })
})
const request = (
  method: string,
  url: string,
  body?: unknown,
  token = 'test-service-token',
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
    { durableTasks: true, transcription: false, version: 2 },
  )
  const create = await POST(
    request('POST', '/api/platform/tasks', {
      externalId: 'integration-session',
      title: 'Planning meeting',
      inputs: [],
    }),
    context('tasks'),
  )
  assert.equal(create.status, 201)
  const task = await create.json()
  assert.equal(typeof task.id, 'string')
  const second = await (
    await POST(
      request('POST', '/api/platform/tasks', {
        externalId: 'integration-session',
        title: 'Planning meeting',
        inputs: [],
      }),
      context('tasks'),
    )
  ).json()
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
  assert.equal((await patch.json()).status, 'COMPLETED')
  await assert.rejects(
    payload.find({ collection: 'meetings', overrideAccess: false }),
    { status: 403 },
  )
})

test('audio uploads are complete before exposure and support authenticated byte ranges', async () => {
  const bytes = Buffer.from('0123456789abcdef')
  const uploaded = await upload(
    new Request('http://localhost:3000/upload?filename=sample.wav', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer test-service-token',
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
  assert.equal(full.headers.get('Content-Length'), '16')
  assert.deepEqual(Buffer.from(await full.arrayBuffer()), bytes)
  const part = await download(
    new Request(`http://localhost:3000${url}`, {
      headers: { Range: 'bytes=4-8' },
    }),
    ctx,
  )
  assert.equal(part.status, 206)
  assert.equal(await part.text(), '45678')
  assert.equal(part.headers.get('Content-Range'), 'bytes 4-8/16')
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
  const { createTask, persistOutput } = await import('../src/server/tasks')
  const { patchTask } = await import('../src/server/atomic')
  const old = await createTask(payload, {
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
  const newer = await createTask(payload, {
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
  const { createTask, persistOutput } = await import('../src/server/tasks')
  const externalId = 'concurrent-' + Date.now()
  const older = await createTask(payload, {
    externalId,
    title: 'Concurrent',
    inputs: [],
  })
  const newer = await createTask(payload, {
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
