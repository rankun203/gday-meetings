import { LoginForm } from './form'
import { serverEnv } from '../../../lib/env'
import { headers } from 'next/headers'
import { redirect } from 'next/navigation'
import { getBrowserPrincipal, authIssuer } from '../../../server/auth'
export const metadata = {
  title: 'Sign in · GdayMeetings',
  robots: { index: false, follow: false },
}
export default async function SignIn({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}) {
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(await searchParams)) {
    if (Array.isArray(value)) value.forEach((item) => params.append(key, item))
    else if (value !== undefined) params.append(key, value)
  }
  if (
    params.has('sig') &&
    (await getBrowserPrincipal(
      new Request(authIssuer(), { headers: await headers() }),
    ))
  )
    redirect('/api/auth/oauth2/authorize?' + params.toString())
  return (
    <main className="oauth">
      <p className="eyebrow">GDAY / MEETINGS</p>
      <h1>Welcome back.</h1>
      <p>Sign in with your GdayMeetings account to continue.</p>
      <LoginForm upstream={Boolean(serverEnv().OIDC_UPSTREAM_ISSUER)} />
      <p>Need an account? Ask your GdayMeetings administrator.</p>
    </main>
  )
}
