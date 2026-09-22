import { headers } from 'next/headers'
import { redirect } from 'next/navigation'
import { getBrowserPrincipal, authIssuer } from '../../../server/auth'
import { serverEnv } from '../../../lib/env'
import { AccountActions } from './actions'
export const dynamic = 'force-dynamic'
export default async function Account() {
  const principal = await getBrowserPrincipal(
    new Request(authIssuer(), { headers: await headers() }),
  )
  if (!principal) redirect('/sign-in')
  return (
    <main className="oauth">
      <p className="eyebrow">GDAY / MEETINGS</p>
      <h1>Your account</h1>
      <p>{principal.user.email}</p>
      <p>Access: {principal.user.role}</p>
      {principal.user.role === 'admin' && (
        <p>
          <a href="/admin">Manage recordings and users</a>
        </p>
      )}
      <AccountActions upstream={Boolean(serverEnv().OIDC_UPSTREAM_ISSUER)} />
    </main>
  )
}
