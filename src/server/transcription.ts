import { sql } from '@payloadcms/db-postgres'
import type { Payload } from 'payload'
import { z } from 'zod'
import { capability, publicURL } from './security'
import { serverEnv } from '../lib/env'

export const executionOptions = z
  .object({
    language: z.string().min(1).max(40).default('auto'),
    diarize: z.boolean().default(true),
    minSpeakers: z.number().int().positive().max(100).optional(),
    maxSpeakers: z.number().int().positive().max(100).optional(),
  })
  .refine(
    (value) =>
      !value.minSpeakers ||
      !value.maxSpeakers ||
      value.minSpeakers <= value.maxSpeakers,
    'minSpeakers must not exceed maxSpeakers',
  )

type ExecutionState =
  'QUEUED' | 'SUBMITTING' | 'SUBMITTED' | 'SUBMISSION_UNKNOWN' | 'FINISHED'
type Task = {
  id: string
  status: string
  executionState?: string | null
  executionRevision?: number | null
  executionOptions?: unknown
  submissionStartedAt?: string | null
  nextPollAt?: string | null
  runpodJobId?: string | null
  inputs?:
    | {
        url: string
        trackName?: string | null
        sourceType?: string | null
        channels?: number | null
      }[]
    | null
}
type Config = { endpoint: string; key: string }
type Patch = {
  executionState?: ExecutionState
  status?: 'FAILED'
  error?: string
  runpodJobId?: string
  submissionStartedAt?: string
  nextPollAt?: string | null
}

export function runpodConfiguration(): Config | null {
  const env = serverEnv()
  const endpoint = env.RUNPOD_ENDPOINT_URL?.replace(/\/$/, '')
  const key = env.RUNPOD_API_KEY
  if (!endpoint || !key) return null
  return { endpoint, key }
}

/** Never permit user input to turn the remote GPU worker into an arbitrary URL fetcher. */
export function validateOwnedAudio(inputs: NonNullable<Task['inputs']>) {
  if (!inputs.length) throw new Error('At least one audio input is required')
  const names = new Set<string>()
  inputs.forEach((input, index) => {
    const url = new URL(input.url)
    const name = input.trackName || `track-${index + 1}`
    if (names.has(name)) throw new Error('Track names must be unique')
    names.add(name)
    const match =
      /^\/files\/([0-9a-f-]{36}\.(?:wav|flac|mp3|m4a|ogg|opus|mp4|webm|aac))$/.exec(
        url.pathname,
      )
    if (
      url.origin !== new URL(publicURL('/')).origin ||
      !match ||
      url.username ||
      url.password ||
      url.hash ||
      url.searchParams.get('token') !== capability('audio', match[1])
    )
      throw new Error(
        'Execution inputs must be signed audio URLs uploaded to this platform',
      )
  })
}

async function rows(payload: Payload, query: ReturnType<typeof sql>) {
  const db = payload.db as unknown as {
    name: string
    drizzle: {
      all: (query: ReturnType<typeof sql>) => Promise<Record<string, unknown>[]>
      execute: (
        query: ReturnType<typeof sql>,
      ) => Promise<{ rows: Record<string, unknown>[] }>
    }
  }
  return db.name === 'sqlite'
    ? db.drizzle.all(query)
    : (await db.drizzle.execute(query)).rows
}

/** State changes are a single SQL compare-and-set across processes and both adapters. */
async function change(payload: Payload, task: Task, patch: Patch) {
  const fields = [
    sql`execution_revision = COALESCE(execution_revision, 0) + 1`,
    sql`updated_at = ${new Date().toISOString()}`,
  ]
  if (patch.executionState !== undefined)
    fields.push(sql`execution_state = ${patch.executionState}`)
  if (patch.status !== undefined) fields.push(sql`status = ${patch.status}`)
  if (patch.error !== undefined) fields.push(sql`error = ${patch.error}`)
  if (patch.runpodJobId !== undefined)
    fields.push(sql`runpod_job_id = ${patch.runpodJobId}`)
  if (patch.submissionStartedAt !== undefined)
    fields.push(sql`submission_started_at = ${patch.submissionStartedAt}`)
  if (patch.nextPollAt !== undefined)
    fields.push(sql`next_poll_at = ${patch.nextPollAt}`)
  const result = await rows(
    payload,
    sql`UPDATE tasks SET ${sql.join(fields, sql`, `)} WHERE id = ${task.id} AND status = 'PENDING' AND COALESCE(execution_revision, 0) = ${task.executionRevision || 0} RETURNING id`,
  )
  return result.length === 1
}

const outputSchema = z
  .object({
    tracks: z.record(z.string(), z.unknown()),
    language: z.string(),
    model: z.string(),
  })
  .passthrough()

export async function advanceTranscription(
  payload: Payload,
  id: string,
  options: {
    config?: Config
    fetch?: typeof fetch
    now?: number
  } = {},
) {
  const config = options.config || runpodConfiguration()
  if (!config) return
  const task: Task = await payload.findByID({
    collection: 'tasks',
    id,
    depth: 0,
    overrideAccess: true,
  })
  if (task.status !== 'PENDING' || !task.executionState) return
  // A process can stop after the durable output insert but before its projection.
  // Repair from our own database before trusting an expired/failed provider job.
  const saved = await payload.find({
    collection: 'outputs',
    where: {
      and: [
        { task: { equals: id } },
        { type: { equals: 'TRANSCRIPT_OUTPUT' } },
      ],
    },
    limit: 1,
    depth: 0,
    overrideAccess: true,
  })
  if (saved.docs[0]) {
    if (saved.docs[0].body === null || saved.docs[0].body === undefined)
      throw new Error('Durable transcript output has no body')
    const { persistOutput } = await import('./tasks')
    await persistOutput(payload, id, {
      type: 'TRANSCRIPT_OUTPUT',
      body: saved.docs[0].body,
    })
    return
  }
  const now = options.now ?? Date.now()
  const later = new Date(now + 15_000).toISOString()
  const fetcher = options.fetch || fetch
  if (task.executionState === 'SUBMITTING') {
    if (
      !task.submissionStartedAt ||
      now - Date.parse(task.submissionStartedAt) > 120_000
    )
      await change(payload, task, {
        executionState: 'SUBMISSION_UNKNOWN',
        error:
          'Submission acknowledgement was interrupted. Awaiting worker callback; create a new attempt only after checking the provider.',
        nextPollAt: null,
      })
    return
  }
  if (task.executionState === 'QUEUED') {
    let input: ReturnType<typeof executionOptions.parse>
    try {
      input = executionOptions.parse(task.executionOptions || {})
      validateOwnedAudio(task.inputs || [])
    } catch {
      await change(payload, task, {
        executionState: 'FINISHED',
        status: 'FAILED',
        error: 'Invalid transcription options or audio inputs',
      })
      return
    }
    if (
      !(await change(payload, task, {
        executionState: 'SUBMITTING',
        submissionStartedAt: new Date(now).toISOString(),
      }))
    )
      return
    const claimed = {
      ...task,
      executionRevision: (task.executionRevision || 0) + 1,
    }
    // There is intentionally no POST retry: a missing acknowledgement does not prove rejection.
    try {
      const response = await fetcher(`${config.endpoint}/run`, {
        method: 'POST',
        redirect: 'error',
        signal: AbortSignal.timeout(60_000),
        headers: {
          Authorization: `Bearer ${config.key}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          input: {
            tracks: task.inputs!.map((track, index) => ({
              audio_url: track.url,
              track_name: track.trackName || `track-${index + 1}`,
              source_type: track.sourceType || 'system',
              channels: track.channels || 1,
            })),
            language: input.language,
            diarize: input.diarize,
            ...(input.minSpeakers === undefined
              ? {}
              : { min_speakers: input.minSpeakers }),
            ...(input.maxSpeakers === undefined
              ? {}
              : { max_speakers: input.maxSpeakers }),
            result_sink: {
              url: publicURL(`/api/platform/tasks/${id}/outputs`),
              token: capability('result', id),
            },
          },
        }),
      })
      if ([400, 401, 403, 404, 422].includes(response.status)) {
        await change(payload, claimed, {
          executionState: 'FINISHED',
          status: 'FAILED',
          error: `RunPod rejected submission (HTTP ${response.status})`,
        })
        return
      }
      if (!response.ok)
        throw new Error('Submission acknowledgement unavailable')
      const result = z
        .object({ id: z.string().min(1) })
        .parse(await response.json())
      await change(payload, claimed, {
        executionState: 'SUBMITTED',
        runpodJobId: result.id,
        nextPollAt: later,
        error: '',
      })
    } catch {
      await change(payload, claimed, {
        executionState: 'SUBMISSION_UNKNOWN',
        nextPollAt: null,
        error:
          'RunPod submission may have been accepted. Awaiting worker callback; automatic resubmission is disabled.',
      })
    }
    return
  }
  if (
    task.executionState !== 'SUBMITTED' ||
    !task.runpodJobId ||
    (task.nextPollAt && Date.parse(task.nextPollAt) > now)
  )
    return
  try {
    const response = await fetcher(
      `${config.endpoint}/status/${encodeURIComponent(task.runpodJobId)}`,
      {
        headers: { Authorization: `Bearer ${config.key}` },
        redirect: 'error',
        signal: AbortSignal.timeout(30_000),
      },
    )
    if (response.status === 404) {
      await change(payload, task, {
        executionState: 'SUBMISSION_UNKNOWN',
        nextPollAt: null,
        error:
          'RunPod no longer retains this job. Awaiting its durable result callback.',
      })
      return
    }
    if (!response.ok) throw new Error('Status unavailable')
    const result = z
      .object({ status: z.string(), output: z.unknown().optional() })
      .parse(await response.json())
    if (result.status === 'COMPLETED') {
      const output = outputSchema.parse(result.output)
      const { persistOutput } = await import('./tasks')
      await persistOutput(payload, id, {
        type: 'TRANSCRIPT_OUTPUT',
        body: output,
      })
      return
    }
    if (['FAILED', 'CANCELLED', 'TIMED_OUT'].includes(result.status)) {
      await change(payload, task, {
        executionState: 'FINISHED',
        status: 'FAILED',
        error: `RunPod job ${result.status.toLowerCase()}`,
        nextPollAt: null,
      })
      return
    }
    await change(payload, task, {
      nextPollAt: later,
      error: ['IN_QUEUE', 'IN_PROGRESS'].includes(result.status)
        ? ''
        : 'Unrecognized provider status; continuing recovery',
    })
  } catch {
    await change(payload, task, {
      nextPollAt: later,
      error:
        'Temporary status or result retrieval failure; recovery will retry',
    })
  }
}

export async function scanTranscriptions(payload: Payload) {
  const config = runpodConfiguration()
  if (!config) return
  const tasks = await payload.find({
    collection: 'tasks',
    where: {
      and: [
        { status: { equals: 'PENDING' } },
        { executionState: { in: ['QUEUED', 'SUBMITTING', 'SUBMITTED'] } },
      ],
    },
    sort: 'updatedAt',
    limit: 100,
    depth: 0,
    overrideAccess: true,
  })
  // Bounded parallelism: slow provider requests must not starve all other tasks.
  for (let start = 0; start < tasks.docs.length; start += 4)
    await Promise.all(
      tasks.docs.slice(start, start + 4).map((task) =>
        advanceTranscription(payload, task.id, { config }).catch(() => {
          console.error('Transcription recovery tick failed')
        }),
      ),
    )
}
