import { serverEnv } from '../lib/env'
import type { PayloadRequest } from 'payload'
import { audioDirectory as directory } from './storage'
import { randomUUID } from 'node:crypto'
import { createReadStream, createWriteStream } from 'node:fs'
import { mkdir, stat, unlink } from 'node:fs/promises'
import path from 'node:path'
import { Readable, Transform } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { cms } from './payload'
import { capability, capabilityAuthorized, HttpError } from './security'
export async function upload(request: Request, req: PayloadRequest) {
  const originalName =
    new URL(request.url).searchParams.get('filename') || 'recording.wav'
  if (originalName.length > 255) throw new HttpError(400, 'Filename too long')
  const extension = path.extname(originalName).toLowerCase()
  if (
    ![
      '.wav',
      '.flac',
      '.mp3',
      '.m4a',
      '.ogg',
      '.opus',
      '.mp4',
      '.webm',
      '.aac',
    ].includes(extension)
  )
    throw new HttpError(400, 'Unsupported audio extension')
  const key = randomUUID() + extension
  await mkdir(directory(), { recursive: true })
  const temporary = path.join(directory(), `${key}.partial`)
  let size = 0
  const limit = serverEnv().MAX_UPLOAD_BYTES
  try {
    if (!request.body) throw new HttpError(400, 'Audio body required')
    const limiter = new Transform({
      transform(chunk, _encoding, callback) {
        size += chunk.length
        callback(
          size > limit
            ? new HttpError(
                413,
                'Audio exceeds the configured upload limit (maximum 500 MB). Prefer Opus, M4A or MP3.',
              )
            : null,
          chunk,
        )
      },
    })
    await pipeline(
      Readable.fromWeb(request.body as never),
      limiter,
      createWriteStream(temporary, { flags: 'wx' }),
    )
    if (!size) throw new HttpError(400, 'Audio body is empty')
    const payload = await cms()
    const record = await payload.create({
      collection: 'audio-files',
      overrideAccess: false,
      req,
      data: {} as never,
      file: {
        name: originalName,
        size,
        mimetype:
          request.headers.get('content-type') || 'application/octet-stream',
        data: Buffer.alloc(0),
        tempFilePath: temporary,
      },
    })
    await unlink(temporary).catch(() => {})
    return {
      url: `/files/${record.storageKey}?token=${capability('audio', record.storageKey)}`,
    }
  } catch (error) {
    await unlink(temporary).catch(() => {})
    throw error
  }
}
export async function download(request: Request, key: string) {
  if (
    !/^[0-9a-f-]{36}\.(wav|flac|mp3|m4a|ogg|opus|mp4|webm|aac)$/.test(key) ||
    !capabilityAuthorized(
      'audio',
      key,
      new URL(request.url).searchParams.get('token') || '',
    )
  )
    throw new HttpError(401, 'Unauthorized')
  const payload = await cms()
  const record = await payload.find({
    collection: 'audio-files',
    where: { storageKey: { equals: key } },
    limit: 1,
    overrideAccess: true,
  })
  if (!record.docs.length) throw new HttpError(404, 'Audio not found')
  const file = path.join(directory(), key)
  let info
  try {
    info = await stat(file)
  } catch {
    throw new HttpError(404, 'Audio not found')
  }
  const headers = new Headers({
    'Content-Type': 'application/octet-stream',
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
  })
  let start = 0,
    end = info.size - 1,
    status = 200
  const range = request.headers.get('range')
  if (range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(range)
    if (!match || (!match[1] && !match[2]))
      return new Response(null, {
        status: 416,
        headers: { 'Content-Range': `bytes */${info.size}` },
      })
    if (!match[1]) start = Math.max(0, info.size - Number(match[2]))
    else {
      start = Number(match[1])
      if (match[2]) end = Math.min(end, Number(match[2]))
    }
    if (
      !Number.isSafeInteger(start) ||
      !Number.isSafeInteger(end) ||
      start > end ||
      start >= info.size
    )
      return new Response(null, {
        status: 416,
        headers: { 'Content-Range': `bytes */${info.size}` },
      })
    status = 206
    headers.set('Content-Range', `bytes ${start}-${end}/${info.size}`)
  }
  headers.set('Content-Length', String(end - start + 1))
  return new Response(
    request.method === 'HEAD'
      ? null
      : (Readable.toWeb(
          createReadStream(file, { start, end }),
        ) as ReadableStream),
    { status, headers },
  )
}
