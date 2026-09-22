import type { PayloadRequest } from 'payload'
import { audioDirectory as directory, validStorageKey } from './storage'
import { randomUUID } from 'node:crypto'
import { createReadStream, createWriteStream } from 'node:fs'
import { mkdir, rename, stat, unlink } from 'node:fs/promises'
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
  const temporary = path.join(directory(), `${key}.partial`),
    destination = path.join(directory(), key)
  let size = 0
  const limit = Number(process.env.MAX_UPLOAD_BYTES || 2 * 1024 ** 3)
  try {
    if (!request.body) throw new HttpError(400, 'Audio body required')
    const limiter = new Transform({
      transform(chunk, _encoding, callback) {
        size += chunk.length
        callback(
          size > limit
            ? new HttpError(413, 'Audio exceeds upload limit')
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
    await rename(temporary, destination)
    const payload = await cms()
    await payload.create({
      collection: 'audio-files',
      overrideAccess: false,
      req,
      data: {
        storageKey: key,
        originalName,
        size,
        contentType:
          request.headers.get('content-type') || 'application/octet-stream',
      },
    })
    return { url: `/files/${key}?token=${capability('audio', key)}` }
  } catch (error) {
    await Promise.all([
      unlink(temporary).catch(() => {}),
      unlink(destination).catch(() => {}),
    ])
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
