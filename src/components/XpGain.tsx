import { useEffect, useState } from 'react'
import { getXpEvent } from '../lib/api'
import { currentLang, useT } from '../lib/i18n'
import { skinLabel, useProgression } from '../lib/progression'
import type { XpEvent } from '../lib/types'
import { LevelBar } from './LevelBar'

/**
 * 0188: what this match paid -- "+60 XP", the bar toward the next level, and,
 * when it crossed a level, a "Level up!" with whatever that level unlocked.
 * The award is written by the same database transaction that marks the match
 * finished, so it is normally there on the first read; a couple of retries
 * cover a replica that is a beat behind. A match that paid nothing (too short,
 * a sim, XP switched off) renders nothing at all.
 */
export function XpGain({ userId, refKey, xp }: { userId: string; refKey: string; xp: number | undefined }) {
  const t = useT()
  const { skins } = useProgression()
  const [ev, setEv] = useState<XpEvent | null>(null)

  useEffect(() => {
    let alive = true
    let tries = 0
    setEv(null)
    const go = async () => {
      const e = await getXpEvent(userId, refKey)
      if (!alive) return
      if (e) setEv(e)
      else if (++tries < 4) setTimeout(go, 600)
    }
    void go()
    return () => { alive = false }
  }, [userId, refKey])

  if (!ev) return null
  const up = ev.level_after > ev.level_before
  const unlocked = up
    ? skins.filter((s) => s.unlock_level != null && s.unlock_level > ev.level_before && s.unlock_level <= ev.level_after)
    : []
  const lang = currentLang()
  return (
    <div className="xpgain">
      <div className="xpgain-amount">{t('match.xpGained', { xp: ev.xp })}</div>
      <LevelBar xp={xp} />
      {up && (
        <div className="xpgain-up">
          <strong>{t('match.levelUp', { n: ev.level_after })}</strong>
          {unlocked.length > 0 && (
            <span className="xpgain-unlocks">
              {unlocked.map((s) => <em key={s.id}>🔓 {skinLabel(s, lang)}</em>)}
            </span>
          )}
        </div>
      )}
    </div>
  )
}
