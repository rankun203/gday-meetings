'use client'
import { useState } from 'react'
export function AccountActions({ upstream }: { upstream: boolean }) {
  const [error, setError] = useState('')
  async function act(link: boolean) {
    const response = await fetch(
      '/api/auth/' + (link ? 'link-social' : 'sign-out'),
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(
          link ? { provider: 'upstream', callbackURL: '/account' } : {},
        ),
      },
    )
    const data = await response.json()
    if (!response.ok) {
      setError(data.message || 'Unable to complete request')
      return
    }
    location.assign(data.url || '/sign-in')
  }
  return (
    <div>
      {upstream && (
        <button onClick={() => act(true)}>Link external sign-in</button>
      )}{' '}
      <button onClick={() => act(false)}>Sign out</button>
      {error && <p role="alert">{error}</p>}
    </div>
  )
}
