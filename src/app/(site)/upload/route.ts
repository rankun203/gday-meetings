import { upload } from '../../../server/audio'
import { requireService, errorResponse } from '../../../server/security'
export const runtime = 'nodejs'
export async function POST(request: Request) {
  try {
    requireService(request)
    return Response.json(await upload(request), { status: 201 })
  } catch (error) {
    return errorResponse(error)
  }
}
