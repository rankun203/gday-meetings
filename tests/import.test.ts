import { wav } from './helpers/audio'
import assert from 'node:assert/strict'
import { after, test } from 'node:test'
import { createHash } from 'node:crypto'
import { mkdtemp, rm, writeFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { tmpdir } from 'node:os'
const directory = await mkdtemp(path.join(tmpdir(), 'gday-import-'))
Object.assign(process.env, {
  DATA_DIR: directory,
  SERVER_URL: 'http://localhost:3000',
  PAYLOAD_SECRET: 'test-import-secret-at-least-thirty-two-characters',
  NODE_ENV: 'production',
})
if (process.env.DATABASE_ADAPTER !== 'postgres')
  process.env.DATABASE_URI = `file:${directory}/test.db`
const { cms } = await import('../src/server/payload')
const payload = await cms()
const { oauthFixture } = await import('./helpers/oauth')
const { issueUserToken } = await oauthFixture(payload, process.env.SERVER_URL!)
const identity = await issueUserToken('import@example.test')
const { POST, GET } =
  await import('../src/app/(site)/api/platform/[...path]/route')
const { POST: upload } = await import('../src/app/(site)/upload/route')
const hash = (value: string | Buffer) =>
  createHash('sha256').update(value).digest('hex')
function request(method: string, body?: unknown, token = identity.token) {
  return new Request('http://localhost:3000/api/platform/meetings/import', {
    method,
    headers: {
      Authorization: 'Bearer ' + token,
      'Content-Type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
}
const ctx = (id?: string) => ({
  params: Promise.resolve({
    path: ['meetings', 'import', ...(id ? [id] : [])],
  }),
})
async function read(id: string) {
  return GET(request('GET'), ctx(id))
}
async function send(body: unknown, token?: string) {
  return POST(request('POST', body, token), ctx())
}
after(async () => {
  await payload.destroy()
  await rm(directory, { recursive: true, force: true })
})
test('OAuth archive imports preserve edits, native audio, idempotency and verified readback without tasks', async () => {
  const bytes = wav()
  const uploaded = await upload(
    new Request('http://localhost:3000/upload?filename=mic.wav', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + identity.token,
        'Content-Type': 'audio/wav',
      },
      body: bytes,
    }),
  )
  assert.equal(uploaded.status, 201)
  const { url } = await uploaded.json()
  const body = {
    externalId: 'local-one',
    title: 'Edited meeting',
    recordedAt: '2026-09-21T08:00:00Z',
    metadata: { people: [{ id: 'person-one', name: 'Edited speaker' }] },
    artifacts: {
      'transcript.json': {
        segments: [
          { start: 0, end: 1, text: 'Corrected words', speaker: 'person-one' },
        ],
      },
      'extraction_raw.json': {
        tracks: {
          mic: { segments: [{ start: 0, end: 1, text: 'Raw words' }] },
        },
      },
      'metadata.md': 'Original metadata',
      'custom-plan.md': 'Original note',
      'mic.waveform.json': { peaks: [1, 2] },
    },
    audio: [
      { filename: 'mic.wav', url, sha256: hash(bytes), size: bytes.length },
    ],
    importKey: hash('snapshot-one'),
  }
  assert.equal((await send(body, 'wrong')).status, 401)
  assert.equal(
    (
      await send({
        ...body,
        audio: [{ ...body.audio[0], sha256: hash('bad') }],
      })
    ).status,
    400,
  )
  const initial = await send(body)
  assert.equal(initial.status, 201, await initial.clone().text())
  const imported = await initial.json()
  assert.equal(imported.audioCount, 1)
  assert.equal(imported.artifactCount, 5)
  const again = await send(body)
  assert.equal(again.status, 201, await again.clone().text())
  assert.deepEqual(await again.json(), imported)
  const verified = await read(body.externalId)
  assert.equal(verified.status, 200, await verified.clone().text())
  assert.deepEqual(await verified.json(), imported)
  const meeting = await payload.findByID({
    collection: 'meetings',
    id: imported.id,
    depth: 1,
    overrideAccess: true,
  })
  assert.deepEqual(meeting.archiveArtifacts, body.artifacts)
  assert.deepEqual(meeting.archiveMetadata, body.metadata)
  assert.equal(meeting.transcript, 'Corrected words')
  assert.equal(typeof meeting.archiveAudio?.[0].audio, 'object')
  assert.equal(
    (await payload.count({ collection: 'tasks', overrideAccess: true }))
      .totalDocs,
    0,
  )
  assert.equal(
    (await send({ ...body, importKey: hash('different') })).status,
    409,
  )
  assert.equal((await send({ ...body, title: 'Changed' })).status, 409)
  const key = new URL(url, 'http://localhost:3000').pathname.split('/').pop()!
  await writeFile(path.join(directory, 'audio', key), Buffer.from('corrupted'))
  assert.equal((await read(body.externalId)).status, 409)
  assert.equal((await send(body)).status, 409)
  const audio = meeting.archiveAudio![0].audio!
  await payload.delete({
    collection: 'audio-files',
    id: typeof audio === 'object' ? audio.id : audio,
    overrideAccess: true,
  })
  await assert.rejects(stat(path.join(directory, 'audio', key)), {
    code: 'ENOENT',
  })
  const missing = await read(body.externalId)
  assert.equal(missing.status, 409)
  assert.match((await missing.json()).error, /audio metadata is missing/)
})
test('audio-less archives, concurrent retries, collisions and safe artifact names', async () => {
  const body = {
    externalId: 'audio-less',
    title: 'Notes only',
    artifacts: {
      'notes.md': 'Retain this',
      'transcript.json': { segments: [] },
    },
    audio: [],
    importKey: hash('no-audio'),
  }
  const responses = await Promise.all([send(body), send(body)])
  for (const response of responses)
    assert.equal(response.status, 201, await response.clone().text())
  assert.equal((await responses[0].json()).id, (await responses[1].json()).id)
  assert.equal((await read('missing')).status, 404)
  assert.equal(
    (
      await send({
        ...body,
        externalId: 'unsafe',
        artifacts: { '../notes.md': 'bad' },
      })
    ).status,
    400,
  )
  await payload.create({
    collection: 'meetings',
    data: { externalId: 'existing', title: 'CMS-owned' },
    overrideAccess: true,
  })
  assert.equal((await send({ ...body, externalId: 'existing' })).status, 409)
  assert.equal((await read('existing')).status, 409)
})
