import { headers } from 'next/headers'
import { redirect } from 'next/navigation'
import { getBrowserPrincipal, getAuth, authIssuer } from '../../../server/auth'
import { authOrigin } from '../../../server/auth/config'
import { ConsentForm } from './form'
export const dynamic = 'force-dynamic'
export const metadata = {
  title: 'Authorize access · GdayMeetings',
  robots: { index: false, follow: false },
}
export default async function Consent({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}) {
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(await searchParams)) {
    if (Array.isArray(value)) for (const item of value) params.append(key, item)
    else if (value !== undefined) params.append(key, value)
  }
  const principal = await getBrowserPrincipal(
    new Request(authOrigin() + '/consent', { headers: await headers() }),
  )
  if (!principal) redirect('/sign-in')
  const clientResponse = await (
    await getAuth()
  ).handler(
    new Request(
      authIssuer() +
        '/oauth2/public-client?client_id=' +
        encodeURIComponent(params.get('client_id') || ''),
      { headers: await headers() },
    ),
  )
  const client = clientResponse.ok ? await clientResponse.json() : null
  const permissions: Record<string, string> = {
    'mcp:read': 'Search and read meeting transcripts',
    'meetings:read': 'Read recordings and transcription results',
    'meetings:write': 'Upload recordings and request transcription',
    openid: 'Identify your Gday account',
    profile: 'Read your profile',
    email: 'Read your email address',
    offline_access: 'Stay connected using refresh tokens',
  }
  return (
    <main className="oauth">
      <p className="eyebrow">GDAY / MEETINGS</p>
      <h1>Allow access?</h1>
      <p>You are signed in as {principal.user.email}.</p>
      <p>
        Client:{' '}
        <strong>{client?.client_name || params.get('client_id')}</strong>
      </p>
      <ul>
        {(params.get('scope') || '')
          .split(' ')
          .filter(Boolean)
          .map((scope) => (
            <li key={scope}>{permissions[scope] || scope}</li>
          ))}
      </ul>
      <p className="oauth-detail">
        Return address: <code>{params.get('redirect_uri')}</code>
      </p>
      <p>
        Only approve applications you trust to access your meeting workspace.
      </p>
      <ConsentForm oauthQuery={params.toString()} />
    </main>
  )
}
