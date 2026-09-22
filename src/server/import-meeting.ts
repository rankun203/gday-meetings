import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import path from 'node:path'
import type { Payload, PayloadRequest } from 'payload'
import { z } from 'zod'
import type { Meeting } from '../payload-types'
import { audioDirectory } from './storage'
import { capabilityAuthorized, HttpError, publicURL } from './security'
import { transcriptText } from './tasks'
const json = z.json()
export const meetingImportInput = z
  .object({
    externalId: z.string().min(1).max(200),
    title: z.string().min(1).max(500),
    recordedAt: z.iso.datetime({ offset: true }).optional(),
    metadata: json.optional(),
    artifacts: z
      .record(
        z
          .string()
          .max(255)
          .regex(/^[^./\\][^/\\]*\.(json|md|txt)$/),
        json,
      )
      .refine(
        (values) => Object.values(values).every((v) => v !== null),
        'Artifact cannot be null',
      ),
    audio: z
      .array(
        z
          .object({
            filename: z
              .string()
              .min(1)
              .max(255)
              .refine((v) => path.basename(v) === v),
            url: z.string().max(4096),
            sha256: z.string().regex(/^[a-f0-9]{64}$/),
            size: z.number().int().positive().safe(),
          })
          .strict(),
      )
      .max(32),
    importKey: z.string().regex(/^[a-f0-9]{64}$/),
  })
  .strict()
type Input = z.infer<typeof meetingImportInput>
async function digestFile(key: string) {
  const hash = createHash('sha256')
  let size = 0
  try {
    for await (const chunk of createReadStream(
      path.join(audioDirectory(), key),
    )) {
      hash.update(chunk)
      size += chunk.length
    }
  } catch {
    throw new HttpError(409, 'Imported audio is missing or unreadable')
  }
  return { sha256: hash.digest('hex'), size }
}
function canonical(value: unknown): string {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']'
  if (value !== null && typeof value === 'object')
    return (
      '{' +
      Object.entries(value)
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
        .map(([k, v]) => JSON.stringify(k) + ':' + canonical(v))
        .join(',') +
      '}'
    )
  return JSON.stringify(value) ?? 'null'
}
function requestDigest(
  input: Pick<
    Input,
    | 'externalId'
    | 'title'
    | 'recordedAt'
    | 'metadata'
    | 'artifacts'
    | 'importKey'
  > & { audio: Array<{ filename: string; sha256: string; size: number }> },
) {
  return createHash('sha256')
    .update(
      canonical({
        externalId: input.externalId,
        title: input.title,
        recordedAt: input.recordedAt
          ? new Date(input.recordedAt).toISOString()
          : null,
        metadata: input.metadata ?? null,
        artifacts: input.artifacts,
        importKey: input.importKey,
        audio: input.audio.map(({ filename, sha256, size }) => ({
          filename,
          sha256,
          size,
        })),
      }),
    )
    .digest('hex')
}
async function find(payload: Payload, externalId: string, req: PayloadRequest) {
  return (
    await payload.find({
      collection: 'meetings',
      where: { externalId: { equals: externalId } },
      limit: 1,
      depth: 1,
      req,
      overrideAccess: false,
    })
  ).docs[0]
}
async function summary(
  payload: Payload,
  meeting: Meeting,
  req: PayloadRequest,
) {
  if (!meeting.importKey)
    throw new HttpError(409, 'Meeting already exists without an import archive')
  const digest = requestDigest({
    externalId: meeting.externalId,
    title: meeting.title,
    recordedAt: meeting.recordedAt || undefined,
    metadata: (meeting.archiveMetadata ?? null) as Input['metadata'],
    artifacts: (meeting.archiveArtifacts || {}) as Input['artifacts'],
    importKey: meeting.importKey,
    audio: meeting.archiveAudio || [],
  })
  if (digest !== meeting.importDigest)
    throw new HttpError(409, 'Imported archive content has changed')
  for (const entry of meeting.archiveAudio || []) {
    if (!entry.audio)
      throw new HttpError(409, 'Imported audio metadata is missing')
    const id = typeof entry.audio === 'object' ? entry.audio.id : entry.audio
    const record = await payload.find({
      collection: 'audio-files',
      where: { id: { equals: id } },
      limit: 1,
      req,
      overrideAccess: false,
    })
    if (!record.docs[0])
      throw new HttpError(409, 'Imported audio metadata is missing')
    const actual = await digestFile(record.docs[0].storageKey)
    if (actual.sha256 !== entry.sha256 || actual.size !== entry.size)
      throw new HttpError(409, 'Imported audio verification failed')
  }
  return {
    id: meeting.id,
    externalId: meeting.externalId,
    importKey: meeting.importKey,
    audioCount: meeting.archiveAudio?.length || 0,
    artifactCount: Object.keys(meeting.archiveArtifacts || {}).length,
  }
}
export async function getMeetingImport(
  payload: Payload,
  externalId: string,
  req: PayloadRequest,
) {
  const meeting = await find(payload, externalId, req)
  if (!meeting) throw new HttpError(404, 'Meeting import not found')
  return summary(payload, meeting, req)
}
export async function importMeeting(
  payload: Payload,
  input: Input,
  req: PayloadRequest,
) {
  const digest = requestDigest(input)
  const existing = await find(payload, input.externalId, req)
  if (existing) {
    if (
      existing.importKey !== input.importKey ||
      existing.importDigest !== digest
    )
      throw new HttpError(409, 'Meeting already exists with different content')
    return summary(payload, existing, req)
  }
  if (new Set(input.audio.map((a) => a.filename)).size !== input.audio.length)
    throw new HttpError(400, 'Duplicate audio filename')
  const audio = []
  for (const item of input.audio) {
    let url: URL
    try {
      url = new URL(item.url, publicURL('/'))
    } catch {
      throw new HttpError(400, 'Invalid audio URL')
    }
    const key = url.pathname.slice('/files/'.length)
    if (
      url.origin !== new URL(publicURL('/')).origin ||
      !url.pathname.startsWith('/files/') ||
      !/^[0-9a-f-]{36}\.(wav|flac|mp3|m4a|ogg|opus|mp4|webm|aac)$/.test(key) ||
      !capabilityAuthorized('audio', key, url.searchParams.get('token') || '')
    )
      throw new HttpError(400, 'Audio must be an uploaded platform capability')
    const record = (
      await payload.find({
        collection: 'audio-files',
        where: { storageKey: { equals: key } },
        limit: 1,
        req,
        overrideAccess: false,
      })
    ).docs[0]
    if (!record) throw new HttpError(400, 'Uploaded audio metadata not found')
    const actual = await digestFile(key)
    if (actual.sha256 !== item.sha256 || actual.size !== item.size)
      throw new HttpError(400, 'Uploaded audio checksum or size mismatch')
    audio.push({
      audio: record.id,
      filename: item.filename,
      sha256: item.sha256,
      size: item.size,
    })
  }
  const edited = input.artifacts['transcript.json']
  const raw = input.artifacts['extraction_raw.json']
  const transcript =
    edited !== undefined ? transcriptText(edited) : transcriptText(raw)
  let meeting: Meeting
  try {
    meeting = await payload.create({
      collection: 'meetings',
      req,
      overrideAccess: false,
      context: { validatedMeetingImport: true },
      data: {
        externalId: input.externalId,
        title: input.title,
        recordedAt: input.recordedAt,
        transcript,
        importKey: input.importKey,
        importDigest: digest,
        archiveMetadata: input.metadata,
        archiveArtifacts: input.artifacts,
        archiveAudio: audio,
      },
    })
  } catch (error) {
    const raced = await find(payload, input.externalId, req)
    if (!raced) throw error
    if (raced.importKey !== input.importKey || raced.importDigest !== digest)
      throw new HttpError(409, 'Meeting already exists with different content')
    meeting = raced
  }
  return summary(payload, meeting, req)
}
