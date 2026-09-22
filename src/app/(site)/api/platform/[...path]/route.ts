import {
  platformAccess,
  requireWorkerService,
} from '../../../../../server/platform-access'
import { runpodConfiguration } from '../../../../../server/transcription'
import { patchTask } from '../../../../../server/atomic'
import { z } from 'zod'
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
    if (request.method === 'GET' && parts.join('/') === 'capabilities')
      return Response.json({
        durableTasks: true,
        transcription: Boolean(runpodConfiguration()),
        version: 2,
      })
    if (request.method === 'POST' && parts.join('/') === 'tasks') {
      const parsed = taskInput.safeParse(await readJSON(request))
      if (!parsed.success) throw new HttpError(400, parsed.error.message)
      if (req && !parsed.data.execute)
        throw new HttpError(400, 'User submissions require execute: true')
      return Response.json(await createTask(await cms(), parsed.data, req), {
        status: 201,
      })
    }
    if (
      request.method === 'PATCH' &&
      parts[0] === 'tasks' &&
      parts.length === 2
    ) {
      requireWorkerService(request)
      const parsed = z
        .object({
          status: z.enum(['PENDING', 'FAILED']).optional(),
          error: z.string().max(20000).optional(),
          runpodJobId: z.string().max(200).optional(),
        })
        .strict()
        .safeParse(await readJSON(request))
      if (!parsed.success) throw new HttpError(400, parsed.error.message)
      const payload = await cms()
      const current = await getTask(payload, parts[1])
      if (current.status === 'COMPLETED') return Response.json(current)
      await patchTask(payload, parts[1], parsed.data)
      return Response.json(await getTask(payload, parts[1]))
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

export const PATCH = route
