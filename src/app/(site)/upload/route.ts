import { upload } from '../../../server/audio'
import { errorResponse } from '../../../server/security'
import { platformAccess } from '../../../server/platform-access'
export const runtime = 'nodejs'
export async function POST(request: Request) {
  try {
    const req = await platformAccess(request, 'meetings:write')
    return Response.json(await upload(request, req), { status: 201 })
  } catch (error) {
    return errorResponse(error)
  }
}
