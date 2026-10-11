import { useState } from 'react'
import { useAppSettings } from '../lib/useAppSettings'
import { currentLang, useT } from '../lib/i18n'
import { IconAlert, IconClose, IconInfo, IconSparkle, IconTrophy } from './Icons'

/**
 * The announcement strip (0216): one message, written in the admin panel, shown
 * at the top of the menu to everybody who is signed in. English and Spanish are
 * written separately; a player sees theirs, falling back to the other if one is
 * empty. When it is dismissible, the dismissal is remembered per announcement_id
 * in this browser only, and every save in the admin panel bumps that id, so an
 * edited banner comes back for everyone.
 */
const KEY = 'cn.announcement.dismissed'
const read = () => { try { return Number(localStorage.getItem(KEY) ?? 0) || 0 } catch { return 0 } }

const KIND_ICON = { info: IconInfo, update: IconSparkle, warning: IconAlert, event: IconTrophy } as const

export function AnnouncementBanner() {
  const t = useT()
  const s = useAppSettings()
  const [dismissed, setDismissed] = useState(read)
  const id = s.announcement_id ?? 0
  const en = (s.announcement_text ?? '').trim()
  const es = (s.announcement_text_es ?? '').trim()
  const text = currentLang() === 'es' ? es || en : en || es
  if (!s.announcement_enabled || !text) return null
  const canClose = s.announcement_dismissible !== false
  if (canClose && dismissed >= id && id > 0) return null
  const kind = s.announcement_kind ?? 'info'
  const Icon = KIND_ICON[kind]
  return (
    <div className={`announce is-${kind}`} role="status">
      <Icon className="announce-icon" />
      <span className="announce-text">{text}</span>
      {canClose && (
        <button
          type="button" className="announce-x" aria-label={t('common.close')}
          onClick={() => {
            setDismissed(id)
            try { localStorage.setItem(KEY, String(id)) } catch { /* private mode: it just comes back next visit */ }
          }}
        >
          <IconClose />
        </button>
      )}
    </div>
  )
}
