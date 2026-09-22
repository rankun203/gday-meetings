import { discovery } from '../../../../server/auth/discovery'
export const dynamic = 'force-dynamic'
export const GET = (request: Request) => discovery(request, 'oidc')
