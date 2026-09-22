import { projectTranscript } from './atomic'
import { createHash } from 'node:crypto'
import {
  executionOptions,
  runpodConfiguration,
  validateOwnedAudio,
} from './transcription'
import { z } from 'zod'
import type { Payload, PayloadRequest } from 'payload'
import { HttpError, publicURL } from './security'
export const taskInput = z
  .object({
    externalId: z.string().min(1).max(200),
    title: z.string().min(1).max(500),
    idempotencyKey: z.string().min(1).max(200),
    executionOptions: executionOptions.optional(),
    inputs: z
      .array(
        z.object({
          url: z.string().min(1).max(4096),
          trackName: z.string().max(200).optional(),
          sourceType: z.string().max(100).optional(),
          channels: z.number().int().positive().max(64).optional(),
        }),
      )
      .min(1)
      .max(32),
  })
  .strict()
export const outputInput = z.object({
  type: z.string().regex(/^[A-Z][A-Z0-9_]{0,63}$/),
  body: z
    .unknown()
    .refine((v) => v !== undefined && v !== null, 'body required'),
})
export async function createTask(
  payload: Payload,
  input: z.infer<typeof taskInput>,
  req: PayloadRequest,
) {
  if (!req.user) throw new HttpError(401, 'Unauthorized')
  if (!runpodConfiguration())
    throw new HttpError(503, 'Server transcription is not configured')
  try {
    validateOwnedAudio(input.inputs)
  } catch {
    throw new HttpError(
      400,
      'Execution requires unique tracks with signed platform audio URLs',
    )
  }
  for (const track of input.inputs) {
    const key = new URL(track.url).pathname.slice('/files/'.length)
    const stored = await payload.find({
      collection: 'audio-files',
      where: { storageKey: { equals: key } },
      limit: 1,
      req,
      overrideAccess: false,
    })
    if (!stored.docs.length)
      throw new HttpError(400, 'Audio input does not exist')
  }
  const idempotencyKey = createHash('sha256')
    .update(
      JSON.stringify([req.user.id, input.externalId, input.idempotencyKey]),
    )
    .digest('hex')
  const requestHash = createHash('sha256')
    .update(
      JSON.stringify({
        externalId: input.externalId,
        title: input.title,
        inputs: input.inputs,
        options: executionOptions.parse(input.executionOptions || {}),
      }),
    )
    .digest('hex')
  const existing = await payload.find({
    collection: 'tasks',
    where: { idempotencyKey: { equals: idempotencyKey } },
    limit: 1,
    req,
    overrideAccess: false,
  })
  if (existing.docs[0]) {
    if (existing.docs[0].requestHash !== requestHash)
      throw new HttpError(
        409,
        'Idempotency key already used for different inputs',
      )
    return {
      id: existing.docs[0].id,
      status: existing.docs[0].status,
      executionState: existing.docs[0].executionState,
    }
  }
  let result = await payload.find({
    collection: 'meetings',
    where: { externalId: { equals: input.externalId } },
    limit: 1,
    req,
    overrideAccess: false,
  })
  let meeting = result.docs[0]
  if (!meeting) {
    try {
      meeting = await payload.create({
        collection: 'meetings',
        data: { externalId: input.externalId, title: input.title },
        req,
        overrideAccess: false,
      })
    } catch (error) {
      result = await payload.find({
        collection: 'meetings',
        where: { externalId: { equals: input.externalId } },
        limit: 1,
        req,
        overrideAccess: false,
      })
      if (!result.docs[0]) throw error
      meeting = result.docs[0]
    }
  }
  let task
  try {
    task = await payload.create({
      collection: 'tasks',
      context: { validatedTaskSubmission: true },
      data: {
        meeting: meeting.id,
        status: 'PENDING',
        inputs: input.inputs,
        executionState: 'QUEUED',
        executionOptions: executionOptions.parse(input.executionOptions || {}),
        executionRevision: 0,
        idempotencyKey,
        requestHash,
      },
      req,
      overrideAccess: false,
    })
  } catch (error) {
    if (!idempotencyKey) throw error
    const found = await payload.find({
      collection: 'tasks',
      where: { idempotencyKey: { equals: idempotencyKey } },
      limit: 1,
      req,
      overrideAccess: false,
    })
    if (!found.docs[0]) throw error
    if (found.docs[0].requestHash !== requestHash)
      throw new HttpError(
        409,
        'Idempotency key already used for different inputs',
      )
    task = found.docs[0]
  }
  return {
    id: task.id,
    status: task.status,
    executionState: task.executionState,
  }
}
export async function getTask(
  payload: Payload,
  id: string,
  req?: PayloadRequest,
) {
  const tasks = await payload.find({
    collection: 'tasks',
    where: { id: { equals: id } },
    limit: 1,
    depth: 1,
    req,
    overrideAccess: !req,
  })
  const task = tasks.docs[0]
  if (!task) throw new HttpError(404, 'Task not found')
  const outputs = await payload.find({
    collection: 'outputs',
    where: { task: { equals: id } },
    limit: 0,
    pagination: false,
    depth: 0,
    req,
    overrideAccess: !req,
  })
  return {
    ...task,
    outputs: outputs.docs.map((output) => ({
      id: output.id,
      type: output.type,
      body: output.body,
      downloadURL: publicURL(`/api/platform/tasks/${id}/outputs/${output.id}`),
    })),
  }
}
export function transcriptText(body: unknown): string {
  if (!body || typeof body !== 'object') return ''
  const value = body as Record<string, unknown>
  if (typeof value.transcript === 'string') return value.transcript
  const tracks =
    value.tracks && typeof value.tracks === 'object'
      ? Object.values(value.tracks)
      : []
  const segments = Array.isArray(value.segments)
    ? value.segments
    : tracks
        .flatMap((track) =>
          track &&
          typeof track === 'object' &&
          'segments' in track &&
          Array.isArray(track.segments)
            ? track.segments
            : [],
        )
        .filter((segment) => segment && typeof segment === 'object')
        .sort((a, b) => (Number(a.start) || 0) - (Number(b.start) || 0))
  return segments
    .map((segment) =>
      typeof segment === 'object' &&
      segment &&
      'text' in segment &&
      typeof segment.text === 'string'
        ? segment.text
        : '',
    )
    .filter(Boolean)
    .join('\n')
}
async function persistOutputOnce(
  payload: Payload,
  id: string,
  input: z.infer<typeof outputInput>,
) {
  const task = await getTask(payload, id)
  const key = `${id}:${input.type}`
  let existing = await payload.find({
    collection: 'outputs',
    where: { key: { equals: key } },
    limit: 1,
    overrideAccess: true,
  })
  let output = existing.docs[0]
  if (!output) {
    try {
      output = await payload.create({
        collection: 'outputs',
        data: {
          key,
          task: id,
          type: input.type,
          body: input.body as Record<string, unknown>,
        },
        overrideAccess: true,
      })
    } catch (error) {
      existing = await payload.find({
        collection: 'outputs',
        where: { key: { equals: key } },
        limit: 1,
        overrideAccess: true,
      })
      if (!existing.docs[0]) throw error
      output = existing.docs[0]
    }
  }
  // Replay repairs derived state if a previous process stopped after the durable write.
  if (input.type === 'TRANSCRIPT_OUTPUT') {
    const meetingId =
      typeof task.meeting === 'object' ? task.meeting.id : task.meeting
    const transcript = transcriptText(output.body)
    await projectTranscript(payload, id, String(meetingId), transcript)
  }
  return { id: output.id, type: output.type, persisted: true }
}
export async function searchMeetings(
  payload: Payload,
  query: string,
  req?: PayloadRequest,
) {
  const cleaned = query.trim()
  if (!cleaned || cleaned.length > 500)
    throw new HttpError(400, 'Query must contain 1–500 characters')
  const result = await payload.find({
    collection: 'meetings',
    where: {
      or: [
        { title: { contains: cleaned } },
        { transcript: { contains: cleaned } },
        { externalId: { contains: cleaned } },
      ],
    },
    limit: 30,
    sort: '-updatedAt',
    depth: 0,
    overrideAccess: !req,
    req,
  })
  return {
    meetings: result.docs.map((m) => ({
      id: m.id,
      externalId: m.externalId,
      title: m.title,
      transcript: m.transcript || '',
      updatedAt: m.updatedAt,
    })),
    total: result.totalDocs,
  }
}

/** SQLite allows one writer; transient busy failures can safely replay this idempotent command. */
async function retryPersistOutput(
  payload: Payload,
  id: string,
  input: z.infer<typeof outputInput>,
) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await persistOutputOnce(payload, id, input)
    } catch (error) {
      if (attempt >= 5 || !isBusy(error)) throw error
      await new Promise((resolve) => setTimeout(resolve, 25 * 2 ** attempt))
    }
  }
}

function isBusy(error: unknown): boolean {
  if (!(error instanceof Error)) return false
  return (
    /SQLITE_BUSY|database is locked/.test(error.message) ||
    Boolean(error.cause && isBusy(error.cause))
  )
}
const sqliteWriters = new WeakMap<Payload, Promise<void>>()
/** libsql shares a connection in-process, so overlapping immediate transactions must queue. */
export function persistOutput(
  payload: Payload,
  id: string,
  input: z.infer<typeof outputInput>,
) {
  if (payload.db.name !== 'sqlite')
    return retryPersistOutput(payload, id, input)
  const previous = sqliteWriters.get(payload) || Promise.resolve()
  const result = previous.then(() => retryPersistOutput(payload, id, input))
  sqliteWriters.set(
    payload,
    result.then(
      () => undefined,
      () => undefined,
    ),
  )
  return result
}
