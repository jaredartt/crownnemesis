import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { useT } from '../lib/i18n'
import { Logo } from './Logo'
import { containsSlur } from '../lib/profanity'

function EyeIcon({ open }: { open: boolean }) {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" fill="none"
         stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" aria-hidden="true">
      <path d="M1.2 8S3.9 3.3 8 3.3 14.8 8 14.8 8 12.1 12.7 8 12.7 1.2 8 1.2 8Z" />
      <circle cx="8" cy="8" r="2.1" />
      {!open && <path d="M2.4 2.4l11.2 11.2" />}
    </svg>
  )
}

/** A password input with its own show/hide toggle. */
function PasswordField({
  label, value, onChange, autoComplete, id,
}: {
  label: string
  value: string
  onChange: (v: string) => void
  autoComplete: string
  id: string
}) {
  const [show, setShow] = useState(false)
  const t = useT()
  return (
    <label htmlFor={id}>
      <span>{label}</span>
      <div className="field">
        <input
          id={id}
          type={show ? 'text' : 'password'}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          autoComplete={autoComplete}
          minLength={6}
          required
        />
        <button
          type="button"
          className="eye"
          onClick={() => setShow((s) => !s)}
          aria-label={t(show ? 'auth.hide' : 'auth.show', { what: label.toLowerCase() })}
          aria-pressed={show}
          tabIndex={-1}
        >
          <EyeIcon open={show} />
        </button>
      </div>
    </label>
  )
}
export function Auth() {
  const t = useT()
  const [mode, setMode] = useState<'in' | 'up'>('in')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [username, setUsername] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const signingUp = mode === 'up'
  // Only complain once they have actually typed something into the second box.
  const mismatch = signingUp && confirm.length > 0 && password !== confirm
  // Only actually block on a *visible* mismatch. Disabling the button on an
  // empty form just makes it look broken; the browser's own required-field
  // validation covers the rest.
  // 0174: a slur in the display name blocks the button, same check the server runs.
  const nameSlur = signingUp && containsSlur(username)
  const canSubmit = !busy && !mismatch && !nameSlur

  function switchMode() {
    setMode(signingUp ? 'in' : 'up')
    setConfirm('')
    setErr(null)
    setMsg(null)
  }

  // Google sign-in / sign-up in one: Supabase sends them to Google and back to
  // this page; a first-time Google user gets a profile from the same
  // handle_new_user trigger as an email signup (name from their address).
  async function google() {
    setBusy(true)
    setErr(null)
    setMsg(null)
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: window.location.origin + window.location.pathname },
    })
    if (error) {
      setErr(error.message)
      setBusy(false)
    }
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (signingUp && password !== confirm) {
      setErr(t('auth.mismatch'))
      return
    }
    setBusy(true)
    setErr(null)
    setMsg(null)
    try {
      if (signingUp) {
        const { data, error } = await supabase.auth.signUp({
          email,
          password,
          options: { data: { username: username.trim() } },
        })
        if (error) throw error
        if (!data.session) setMsg(t('auth.confirmEmail'))
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password })
        if (error) throw error
      }
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="center-stage">
      <div className="panel auth">
        <Logo className="logo logo-hero" title="Crown Nemesis" />
        <h1 className="wordmark">CROWN<br />NEMESIS</h1>
        <p className="muted">{t('app.tagline')}</p>

        <button type="button" className="btn google-btn" onClick={google} disabled={busy}>
          <svg viewBox="0 0 48 48" width="18" height="18" aria-hidden="true">
            <path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9.1 3.6l6.8-6.8C35.8 2.4 30.3 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.9 6.1C12.4 13.5 17.7 9.5 24 9.5z"/>
            <path fill="#4285F4" d="M46.5 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.7c-.6 3-2.3 5.5-4.8 7.2l7.6 5.9c4.4-4.1 7-10.1 7-17.6z"/>
            <path fill="#FBBC05" d="M10.5 28.7a14.5 14.5 0 0 1 0-9.4l-7.9-6.1a24 24 0 0 0 0 21.6l7.9-6.1z"/>
            <path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.6-5.9c-2.1 1.4-4.9 2.3-8.3 2.3-6.3 0-11.6-4-13.5-9.8l-7.9 6.1C6.5 42.6 14.6 48 24 48z"/>
          </svg>
          <span>{t('auth.google')}</span>
        </button>
        <div className="auth-or" aria-hidden="true"><span>{t('auth.or')}</span></div>

        <form onSubmit={submit}>
          {signingUp && (
            <label htmlFor="cn-username">
              <span>{t('auth.displayName')}</span>
              <input
                id="cn-username"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                placeholder={t('auth.displayNamePlaceholder')}
                minLength={2}
                maxLength={20}
                required
              />
              {nameSlur && <span className="error tiny" role="alert">{t('profile.slurUsername')}</span>}
            </label>
          )}

          <label htmlFor="cn-email">
            <span>{t('auth.email')}</span>
            <input
              id="cn-email"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              required
            />
          </label>

          <PasswordField
            id="cn-password"
            label={t('auth.password')}
            value={password}
            onChange={setPassword}
            autoComplete={signingUp ? 'new-password' : 'current-password'}
          />

          {signingUp && (
            <>
              <PasswordField
                id="cn-confirm"
                label={t('auth.repeatPassword')}
                value={confirm}
                onChange={setConfirm}
                autoComplete="new-password"
              />
              {mismatch && <p className="error">{t('auth.mismatch')}</p>}
            </>
          )}

          {err && <p className="error">{err}</p>}
          {msg && <p className="notice">{msg}</p>}

          <button className="btn primary" disabled={!canSubmit}>
            {busy ? '…' : t(signingUp ? 'auth.createAccount' : 'auth.signIn')}
          </button>
        </form>

        <button className="linkbtn" onClick={switchMode}>
          {t(signingUp ? 'auth.haveAccount' : 'auth.noAccount')}
        </button>
      </div>
    </div>
  )
}
