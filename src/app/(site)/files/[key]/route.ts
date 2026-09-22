import { download } from '../../../../server/audio'
import { errorResponse } from '../../../../server/security'
export const runtime = 'nodejs'
export async function GET(
  request: Request,
  { params }: { params: Promise<{ key: string }> },
) {
  try {
    return await download(request, (await params).key)
  } catch (error) {
    return errorResponse(error)
  }
}
export const HEAD = GET
