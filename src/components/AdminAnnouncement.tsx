import { useEffect, useState } from 'react'
import { setAnnouncement, useAppSettings } from '../lib/useAppSettings'
import { IconAlert, IconInfo, IconSparkle, IconTrophy } from './Icons'

type Kind = 'info' | 'update' | 'warning' | 'event'
const KINDS: [Kind, string, typeof IconInfo][] = [
  ['info', 'Info', IconInfo], ['update', 'Update', IconSparkle],
  ['warning', 'Warning', IconAlert], ['event', 'Event', IconTrophy],
]

/**
 * Admin Mode -> Announcement (0216). The banner at the top of the menu. Write it
 * in English and Spanish, pick a style, publish. Publishing bumps the banner's
 * id, so anyone who dismissed the last one sees this one; "Switch off" hides it
 * for everybody without losing the text.
 */
export function AdminAnnouncement() {
  const s = useAppSettings()
  const [en, setEn] = useState(s.announcement_text ?? '')
  const [es, setEs] = useState(s.announcement_text_es ?? '')
  const [kind, setKind] = useState<Kind>(s.announcement_kind ?? 'info')
  const [closable, setClosable] = useState(s.announcement_dismissible !== false)
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const live = Boolean(s.announcement_enabled)

  useEffect(() => {
    if (dirty) return
    setEn(s.announcement_text ?? ''); setEs(s.announcement_text_es ?? '')
    setKind(s.announcement_kind ?? 'info'); setClosable(s.announcement_dismissible !== false)
  }, [s, dirty])

  async function write(enabled: boolean) {
    setBusy(true); setErr(null)
    try {
      await setAnnouncement({
        announcement_enabled: enabled, announcement_text: en.trim(), announcement_text_es: es.trim(),
        announcement_kind: kind, announcement_dismissible: closable,
      }, enabled && (dirty || !live), s.announcement_id ?? 0)
      setDirty(false)
    } catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }
  const edit = <T,>(set: (v: T) => void) => (v: T) => { setDirty(true); set(v) }
  const Icon = KINDS.find((k) => k[0] === kind)![2]
  const preview = en.trim() || es.trim()

  return (
    <div className="admin-announce">
      <h2>Announcement banner</h2>
      <p className="muted tiny">
        Shows at the top of the menu for every signed-in player. Status:{' '}
        <b>{live ? 'live' : 'off'}</b>.
      </p>

      <label className="feedback-field">
        <span>English ({en.length}/280)</span>
        <textarea rows={2} maxLength={280} value={en} onChange={(e) => edit(setEn)(e.target.value)} />
      </label>
      <label className="feedback-field">
        <span>Spanish ({es.length}/280) · players on Spanish see this; empty falls back to English</span>
        <textarea rows={2} maxLength={280} value={es} onChange={(e) => edit(setEs)(e.target.value)} />
      </label>

      <div className="bal-filters">
        <div className="seg" role="radiogroup" aria-label="Style">
          {KINDS.map(([k, label]) => (
            <button key={k} type="button" role="radio" aria-checked={kind === k}
                    className={kind === k ? 'is-on' : ''} onClick={() => edit(setKind)(k)}>
              {label}
            </button>
          ))}
        </div>
        <label className="bal-min">
          <input type="checkbox" checked={closable} onChange={(e) => edit(setClosable)(e.target.checked)} />
          <span>Players can close it</span>
        </label>
      </div>

      {preview && (
        <div className={`announce is-${kind}`} style={{ margin: '4px 0 12px' }}>
          <Icon className="announce-icon" />
          <span className="announce-text">{preview}</span>
        </div>
      )}

      <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
        <button className="btn primary" disabled={busy || !preview || (live && !dirty)} onClick={() => void write(true)}>
          {busy ? 'Saving…' : live ? 'Update banner' : 'Publish banner'}
        </button>
        {live && (
          <button className="btn ghost" disabled={busy} onClick={() => void write(false)}>Switch off</button>
        )}
      </div>
      {err && <p className="error tiny">{err}</p>}
    </div>
  )
}
