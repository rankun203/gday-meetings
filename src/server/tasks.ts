import { projectTranscript } from './atomic'
import { z } from 'zod'
import type { Payload } from 'payload'
import { capability, HttpError, publicURL } from './security'
export const taskInput = z.object({
  externalId: z.string().min(1).max(200),
  title: z.string().min(1).max(500),
  inputs: z
    .array(
      z.object({
        url: z.string().min(1).max(4096),
        trackName: z.string().max(200).optional(),
        sourceType: z.string().max(100).optional(),
        channels: z.number().int().positive().max(64).optional(),
      }),
    )
    .max(32),
})
export const outputInput = z.object({
  type: z.string().regex(/^[A-Z][A-Z0-9_]{0,63}$/),
  body: z
    .unknown()
    .refine((v) => v !== undefined && v !== null, 'body required'),
})
// This API is an authenticated service boundary. Its callers validate a service
// token or a single-task capability before these explicit system operations.
export async function createTask(
  payload: Payload,
  input: z.infer<typeof taskInput>,
) {
  let result = await payload.find({
    collection: 'meetings',
    where: { externalId: { equals: input.externalId } },
    limit: 1,
    overrideAccess: true,
  })
  let meeting = result.docs[0]
  if (!meeting) {
    try {
      meeting = await payload.create({
        collection: 'meetings',
        data: { externalId: input.externalId, title: input.title },
        overrideAccess: true,
      })
    } catch (error) {
      result = await payload.find({
        collection: 'meetings',
        where: { externalId: { equals: input.externalId } },
        limit: 1,
        overrideAccess: true,
      })
      if (!result.docs[0]) throw error
      meeting = result.docs[0]
    }
  }
  const task = await payload.create({
    collection: 'tasks',
    data: { meeting: meeting.id, status: 'PENDING', inputs: input.inputs },
    overrideAccess: true,
  })
  return {
    id: task.id,
    status: task.status,
    resultSink: {
      url: publicURL(`/api/platform/tasks/${task.id}/outputs`),
      token: capability('result', String(task.id)),
    },
  }
}
export async function getTask(payload: Payload, id: string) {
  const tasks = await payload.find({
    collection: 'tasks',
    where: { id: { equals: id } },
    limit: 1,
    depth: 1,
    overrideAccess: true,
  })
  const task = tasks.docs[0]
  if (!task) throw new HttpError(404, 'Task not found')
  const outputs = await payload.find({
    collection: 'outputs',
    where: { task: { equals: id } },
    limit: 0,
    pagination: false,
    depth: 0,
    overrideAccess: true,
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
export async function searchMeetings(payload: Payload, query: string) {
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
    overrideAccess: true,
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
