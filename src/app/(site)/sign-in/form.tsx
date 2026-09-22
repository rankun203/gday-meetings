'use client'
import { useState, type FormEvent } from 'react'
export function LoginForm({ upstream }: { upstream: boolean }) {
  const [error, setError] = useState(''),
    [busy, setBusy] = useState(false)
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy(true)
    setError('')
    const form = new FormData(event.currentTarget)
    try {
      const query = location.search.slice(1)
      const response = await fetch('/api/auth/sign-in/gday', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          email: form.get('email'),
          password: form.get('password'),
          ...(new URLSearchParams(query).has('sig')
            ? { oauth_query: query }
            : {}),
        }),
      })
      const data = await response.json()
      if (!response.ok) throw Error(data.message || 'Unable to sign in')
      const target = data.url || data.redirect_uri
      if (target) location.assign(target)
      else location.assign('/account')
    } catch (error) {
      setError(error instanceof Error ? error.message : 'Unable to sign in')
      setBusy(false)
    }
  }
  return (
    <form onSubmit={submit} style={{ maxWidth: 420, display: 'grid', gap: 16 }}>
      <label>
        Email
        <input
          name="email"
          type="email"
          autoComplete="username"
          required
          style={{ display: 'block', width: '100%', padding: 12 }}
        />
      </label>
      <label>
        Password
        <input
          name="password"
          type="password"
          autoComplete="current-password"
          required
          style={{ display: 'block', width: '100%', padding: 12 }}
        />
      </label>
      <button className="button" disabled={busy} style={{ margin: 0 }}>
        {busy ? 'Signing in…' : 'Sign in'}
      </button>
      {upstream && (
        <button
          type="button"
          onClick={async () => {
            const response = await fetch('/api/auth/sign-in/social', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                provider: 'upstream',
                callbackURL: location.href,
              }),
            })
            const data = await response.json()
            if (response.ok && data.url) location.assign(data.url)
            else setError(data.message || 'Unable to use external sign-in')
          }}
        >
          Use linked external sign-in
        </button>
      )}
      {error && <p role="alert">{error}</p>}
    </form>
  )
}
