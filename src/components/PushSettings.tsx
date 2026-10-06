import { useEffect, useState } from 'react'
import { useT } from '../lib/i18n'
import {
  PUSH_TYPES, currentSubscription, disablePush, enablePush, fetchPushPrefs, needsHomeScreen,
  pushSupported, savePushPrefs, type PushPrefs, type PushType,
} from '../lib/push'
import { Ti } from './Ti'

/**
 * The bell window's settings view: which notifications may pop up on this
 * phone or computer when the game is not open. The bell itself, and
 * everything in it, is untouched by any of this -- these switches only
 * decide what is PUSHED to the device.
 */
export function PushSettings({ userId, onBack }: { userId: string; onBack: () => void }) {
  const t = useT()
  const [on, setOn] = useState(false)
  const [prefs, setPrefs] = useState<PushPrefs>({})
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  const supported = pushSupported()
  const blocked = supported && typeof Notification !== 'undefined' && Notification.permission === 'denied'

  useEffect(() => {
    let alive = true
    void currentSubscription().then((s) => { if (alive) setOn(!!s && Notification.permission === 'granted') })
    void fetchPushPrefs(userId).then((p) => { if (alive) setPrefs(p) })
    return () => { alive = false }
  }, [userId])

  async function toggleDevice() {
    setBusy(true); setNote(null)
    try {
      if (on) {
        await disablePush()
        setOn(false)
      } else {
        const r = await enablePush()
        setOn(r === 'ok')
        if (r === 'denied') setNote(t('push.denied'))
        else if (r !== 'ok') setNote(t('push.error'))
      }
    } finally { setBusy(false) }
  }

  async function toggleType(k: PushType) {
    const next = { ...prefs, [k]: prefs[k] === false }
    setPrefs(next)
    try { await savePushPrefs(next) } catch { setPrefs(prefs) }
  }

  return (
    <div className="pushset">
      <header className="bellpanel-head pushset-head">
        <button className="linkbtn" onClick={onBack}><Ti name="chevron-left" size="1em" style={{ verticalAlign: '-0.15em' }} /> {t('common.back')}</button>
        <h3>{t('push.title')}</h3>
      </header>
      <p className="muted tiny pushset-note">{t('push.explain')}</p>

      {!supported ? (
        <p className="muted tiny pushset-note">{needsHomeScreen() ? t('push.homeScreen') : t('push.unsupported')}</p>
      ) : (
        <>
          {needsHomeScreen() && <p className="muted tiny pushset-note">{t('push.homeScreen')}</p>}
          <div className="pushset-row">
            <span>{t('push.thisDevice')}</span>
            <button
              className={`toggle${on ? ' is-on' : ''}`} role="switch" aria-checked={on}
              aria-label={t('push.thisDevice')} disabled={busy || blocked} onClick={toggleDevice}
            >
              <i />
            </button>
          </div>
          {blocked && <p className="error tiny pushset-note">{t('push.denied')}</p>}
          {note && <p className="error tiny pushset-note">{note}</p>}

          <div className={`pushset-types${on ? '' : ' is-off'}`}>
            {PUSH_TYPES.map((k) => (
              <div key={k} className="pushset-row">
                <span>{t(`push.type.${k}`)}</span>
                <button
                  className={`toggle${prefs[k] === false ? '' : ' is-on'}`} role="switch"
                  aria-checked={prefs[k] !== false} aria-label={t(`push.type.${k}`)}
                  disabled={!on} onClick={() => toggleType(k)}
                >
                  <i />
                </button>
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  )
}
