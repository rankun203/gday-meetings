import { protectedResourceMetadata } from '../../../../../../server/auth'
export const dynamic = 'force-dynamic'
export const GET = () => Response.json(protectedResourceMetadata('platform'))
