import { getAuth } from '../../../../../server/auth'
export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'
async function handle(request: Request) {
  const length = Number(request.headers.get('content-length') || 0)
  if (length > 65536)
    return Response.json({ error: 'invalid_request' }, { status: 413 })
  if (request.body) {
    const reader = request.body.getReader()
    const chunks: Uint8Array[] = []
    let size = 0
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > 65536) {
        await reader.cancel()
        return Response.json({ error: 'invalid_request' }, { status: 413 })
      }
      chunks.push(value)
    }
    request = new Request(request.url, {
      method: request.method,
      headers: request.headers,
      body: Buffer.concat(chunks),
    })
  }
  const response = await (await getAuth()).handler(request)
  if (new URL(request.url).pathname === '/api/auth/sign-out' && response.ok)
    response.headers.append(
      'Set-Cookie',
      'payload-token=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0',
    )
  return response
}
export const GET = handle
export const POST = handle
