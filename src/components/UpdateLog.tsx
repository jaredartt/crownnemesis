import { useEffect, useMemo, useState } from 'react'
import { ENTRIES, agoShort } from '../lib/changelog'
import { currentLang, useT } from '../lib/i18n'
import { Modal } from './Modal'
import { Ti } from './Ti'

/**
 * Settings -> "Update log": everything that has changed in the game, newest
 * first, one white box per change (coloured icon, title, one line, and how long
 * ago). The entries live in lib/changelog.ts. The "ago" text refreshes every
 * 30 seconds while the window is open.
 */
export function UpdateLog({ onClose }: { onClose: () => void }) {
  const t = useT()
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 30_000)
    return () => window.clearInterval(id)
  }, [])
  const rows = useMemo(
    () => [...ENTRIES].sort((a, b) => b.at.localeCompare(a.at)),
    [],
  )
  const lang = currentLang() === 'es' ? 'es' : 'en'
  return (
    <Modal title={t('updates.title')} onClose={onClose}>
      <div className="uplog">
        {rows.map((r) => (
          <article key={r.at + r.title} className="uplog-item" style={{ '--c': r.color } as React.CSSProperties}>
            <span className="uplog-icon"><Ti name={r.icon} size={20} /></span>
            <div className="uplog-text">
              <div className="uplog-head">
                <h3>{r.title}</h3>
                <time dateTime={r.at} title={new Date(r.at).toLocaleString()}>{agoShort(r.at, lang, now)}</time>
              </div>
              <p>{r.body}</p>
            </div>
          </article>
        ))}
      </div>
    </Modal>
  )
}
