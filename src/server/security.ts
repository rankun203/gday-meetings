import { APIError } from 'payload'
import { createHmac, timingSafeEqual } from 'node:crypto'
export function equal(a: string, b: string): boolean {
  const left = Buffer.from(a),
    right = Buffer.from(b)
  return left.length === right.length && timingSafeEqual(left, right)
}
export function capability(kind: 'audio' | 'result', id: string): string {
  const secret = process.env.PAYLOAD_SECRET
  if (!secret) throw new Error('PAYLOAD_SECRET required')
  return createHmac('sha256', secret).update(`${kind}:${id}`).digest('hex')
}
export function capabilityAuthorized(
  kind: 'audio' | 'result',
  id: string,
  token: string,
): boolean {
  return equal(token, capability(kind, id))
}
export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
    public headers?: HeadersInit,
  ) {
    super(message)
  }
}
export function publicURL(path: string) {
  const base = process.env.SERVER_URL || 'http://localhost:3000'
  return new URL(path, base).toString()
}
export function errorResponse(error: unknown) {
  if (error instanceof HttpError) {
    const headers = new Headers(error.headers)
    headers.set('Cache-Control', 'no-store')
    return Response.json(
      { error: error.message },
      { status: error.status, headers },
    )
  }
  if (error instanceof APIError && error.status >= 400 && error.status < 500)
    return Response.json({ error: error.message }, { status: error.status })
  console.error('Platform request failed', error)
  return Response.json({ error: 'Internal server error' }, { status: 500 })
}
export async function readJSON(
  request: Request,
  limit = 20 * 1024 * 1024,
): Promise<unknown> {
  const reader = request.body?.getReader()
  if (!reader) throw new HttpError(400, 'JSON body required')
  const chunks: Uint8Array[] = []
  let size = 0
  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > limit) {
        await reader.cancel()
        throw new HttpError(413, 'Request too large')
      }
      chunks.push(value)
    }
  } finally {
    reader.releaseLock()
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'))
  } catch {
    throw new HttpError(400, 'Invalid JSON')
  }
}
