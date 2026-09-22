import {
  importMeeting,
  getMeetingImport,
  meetingImportInput,
} from '../../../../../server/import-meeting'
import { platformAccess } from '../../../../../server/platform-access'
import { runpodConfiguration } from '../../../../../server/transcription'
import { cms } from '../../../../../server/payload'
import {
  createTask,
  getTask,
  persistOutput,
  taskInput,
  outputInput,
  searchMeetings,
} from '../../../../../server/tasks'
import {
  capabilityAuthorized,
  errorResponse,
  HttpError,
  readJSON,
} from '../../../../../server/security'
export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'
type Context = { params: Promise<{ path: string[] }> }
async function route(request: Request, { params }: Context) {
  try {
    const parts = (await params).path
    if (
      request.method === 'POST' &&
      parts[0] === 'tasks' &&
      parts[1] &&
      parts[2] === 'outputs' &&
      parts.length === 3
    ) {
      const token =
        request.headers.get('authorization')?.replace(/^Bearer /, '') || ''
      if (!capabilityAuthorized('result', parts[1], token))
        throw new HttpError(401, 'Unauthorized')
      const parsed = outputInput.safeParse(await readJSON(request))
      if (!parsed.success) throw new HttpError(400, parsed.error.message)
      return Response.json(
        await persistOutput(await cms(), parts[1], parsed.data),
      )
    }
    const req = await platformAccess(
      request,
      request.method === 'GET' ? 'meetings:read' : 'meetings:write',
    )
    if (request.method === 'POST' && parts.join('/') === 'meetings/import') {
      const parsed = meetingImportInput.safeParse(await readJSON(request))
      if (!parsed.success) throw new HttpError(400, parsed.error.message)
      return Response.json(await importMeeting(await cms(), parsed.data, req), {
        status: 201,
      })
    }
    if (
      request.method === 'GET' &&
      parts[0] === 'meetings' &&
      parts[1] === 'import' &&
      parts.length === 3
    )
      return Response.json(await getMeetingImport(await cms(), parts[2], req), {
        headers: { 'Cache-Control': 'private, no-store' },
      })
    if (request.method === 'GET' && parts.join('/') === 'capabilities')
      return Response.json({
        durableTasks: true,
        meetingImports: true,
        transcription: Boolean(runpodConfiguration()),
        version: 2,
      })
    if (request.method === 'POST' && parts.join('/') === 'tasks') {
      const parsed = taskInput.safeParse(await readJSON(request))
      if (!parsed.success) throw new HttpError(400, parsed.error.message)
      return Response.json(await createTask(await cms(), parsed.data, req), {
        status: 201,
      })
    }
    if (request.method === 'GET' && parts[0] === 'tasks' && parts.length === 2)
      return Response.json(await getTask(await cms(), parts[1], req))
    if (
      request.method === 'GET' &&
      parts[0] === 'tasks' &&
      parts[2] === 'outputs' &&
      parts.length === 4
    ) {
      const task = await getTask(await cms(), parts[1], req)
      const output = task.outputs.find((o) => String(o.id) === parts[3])
      if (!output) throw new HttpError(404, 'Output not found')
      return new Response(JSON.stringify(output.body), {
        headers: {
          'Content-Type': 'application/json',
          'Content-Disposition': `attachment; filename="${output.type}.json"`,
          'Cache-Control': 'private, no-store',
        },
      })
    }
    if (request.method === 'GET' && parts.join('/') === 'meetings/search')
      return Response.json(
        await searchMeetings(
          await cms(),
          new URL(request.url).searchParams.get('query') || '',
          req,
        ),
      )
    throw new HttpError(404, 'Not found')
  } catch (error) {
    return errorResponse(error)
  }
}
export const GET = route
export const POST = route

export function PATCH(_request: Request, _context: Context) {
  return new Response(null, { status: 405, headers: { Allow: 'GET, POST' } })
}
