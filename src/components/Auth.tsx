import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useT, currentLang } from '../lib/i18n'
import { Logo } from './Logo'
import { containsSlur } from '../lib/profanity'
import { Ti } from './Ti'
import { renderGoogleButton } from '../lib/googleId'

function EyeIcon({ open }: { open: boolean }) {
  return <Ti name={open ? 'eye' : 'eye-off'} size={16} />
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
/** The width Google's button should be drawn at: what is free inside the card. (The button's own box is hidden until
 *  Google has drawn it, so measuring it gives 0 -- which used to fall back to a fixed 320px, wider than the card on
 *  most phones, and that pushed the whole page wider than the screen.) */
function gsiWidth(el: HTMLElement): number {
  const box = el.parentElement
  if (!box) return 280
  const cs = getComputedStyle(box)
  const w = box.clientWidth - parseFloat(cs.paddingLeft || '0') - parseFloat(cs.paddingRight || '0')
  return w > 0 ? w : 280
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

  // Google's own button (names this site instead of the project's supabase.co
  // address on the account chooser). Until it has drawn, and if its script is
  // blocked, the redirect button below stays as the way in.
  const gsiBox = useRef<HTMLDivElement>(null)
  const [gsiReady, setGsiReady] = useState(false)
  // Drawn once per theme, NOT once per sign-in / create-account switch: redrawing emptied the box and reloaded
  // Google's iframe every time the form switched, which is the flicker. "Continue with Google" is true for both modes.
  // The button's colours are chosen when Google draws it, so redraw it whenever the
  // site's theme flips (it used to stay in whatever theme the page opened with).
  const [gsiDark, setGsiDark] = useState(() => document.documentElement.dataset.theme === 'dark')
  useEffect(() => {
    const o = new MutationObserver(() => setGsiDark(document.documentElement.dataset.theme === 'dark'))
    o.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] })
    return () => o.disconnect()
  }, [])
  useEffect(() => {
    const el = gsiBox.current
    if (!el) return
    let dead = false
    const dark = gsiDark
    const lang = currentLang()
    renderGoogleButton(
      el,
      { width: gsiWidth(el), locale: lang, dark, text: 'continue_with' },
      async (token, nonce) => {
        setBusy(true); setErr(null); setMsg(null)
        const { error } = await supabase.auth.signInWithIdToken({ provider: 'google', token, nonce })
        if (error) { setErr(error.message); setBusy(false) }
      },
    ).then(() => { if (!dead) setGsiReady(true) }).catch(() => { if (!dead) setGsiReady(false) })
    return () => { dead = true }
  }, [gsiDark])
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

        <div ref={gsiBox} className="google-gsi" hidden={!gsiReady} />
        <button type="button" className="btn google-btn" onClick={google} disabled={busy} hidden={gsiReady}>
          <Ti name="brand-google" filled size={18} style={{ color: '#4285F4' }} />
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
