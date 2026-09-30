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
