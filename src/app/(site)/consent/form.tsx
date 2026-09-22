'use client'
import { useState } from 'react'
export function ConsentForm({ oauthQuery }: { oauthQuery: string }) {
  const [error, setError] = useState(''),
    [busy, setBusy] = useState(false)
  async function decide(accept: boolean) {
    setBusy(true)
    try {
      const response = await fetch('/api/auth/oauth2/consent', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ accept, oauth_query: oauthQuery }),
      })
      const data = await response.json()
      if (!response.ok)
        throw Error(
          data.error_description || data.message || 'Authorization failed',
        )
      const target = data.redirect_uri || data.url
      if (!target) throw Error('Authorization did not return a redirect')
      location.assign(target)
    } catch (error) {
      setError(error instanceof Error ? error.message : 'Authorization failed')
      setBusy(false)
    }
  }
  return (
    <div>
      <button className="button" disabled={busy} onClick={() => decide(true)}>
        Allow access
      </button>{' '}
      <button disabled={busy} onClick={() => decide(false)}>
        Deny
      </button>
      {error && <p role="alert">{error}</p>}
    </div>
  )
}
