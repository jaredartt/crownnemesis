import { useEffect, useState } from 'react'
import { getMyBalance, getXpEvent } from '../lib/api'
import { currentLang, useT } from '../lib/i18n'
import { skinLabel, useProgression } from '../lib/progression'
import type { Profile, XpEvent } from '../lib/types'
import { IconCrown } from './Icons'
import { CROWNS_ENABLED } from '../lib/features'
import { LevelBar } from './LevelBar'

/**
 * 0188: what this match paid -- "+60 XP", the bar toward the next level, and,
 * when it crossed a level, a "Level up!" with whatever that level unlocked.
 * The award is written by the same database transaction that marks the match
 * finished, so it is normally there on the first read; a couple of retries
 * cover a replica that is a beat behind. A match that paid nothing (too short,
 * a sim, XP switched off) renders nothing at all.
 */
export function XpGain({ userId, refKey, xp, onProfile }: {
  userId: string; refKey: string; xp: number | undefined
  /** Receives the fresh balance so the rest of the app (top bar level, Profile,
   *  the Shop) stops showing the XP the profile had when it was loaded. */
  onProfile?: (patch: Partial<Profile>) => void
}) {
  const t = useT()
  const { skins } = useProgression()
  const [ev, setEv] = useState<XpEvent | null>(null)
  // The bar's own number. `xp` (the app's copy of the profile) is whatever was
  // loaded at sign-in and is NOT refreshed by a match finishing on the server,
  // so the balance is read fresh once the award is known -- and the bar is
  // shown filling from where it was to where it is.
  const [fresh, setFresh] = useState<number | null>(null)
  const [filled, setFilled] = useState(false)

  useEffect(() => {
    let alive = true
    let tries = 0
    setEv(null); setFresh(null); setFilled(false)
    const go = async () => {
      const e = await getXpEvent(userId, refKey)
      if (!alive) return
      if (e) {
        setEv(e)
        const bal = await getMyBalance(userId)
        if (!alive) return
        if (bal) { setFresh(bal.xp); onProfile?.({ xp: bal.xp, crowns: bal.crowns }) }
      }
      else if (++tries < 4) setTimeout(go, 600)
    }
    void go()
    return () => { alive = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId, refKey])

  // Let the "before" bar paint for a beat, then fill it.
  useEffect(() => {
    if (fresh == null) return
    const id = setTimeout(() => setFilled(true), 350)
    return () => clearTimeout(id)
  }, [fresh])

  if (!ev) return null
  const up = ev.level_after > ev.level_before
  const unlocked = up
    ? skins.filter((s) => s.unlock_level != null && s.unlock_level > ev.level_before && s.unlock_level <= ev.level_after)
    : []
  const lang = currentLang()
  const after = fresh ?? xp
  // Same level: show the bar climbing from its old spot. A level-up just shows
  // the new level (a bar that runs backwards would look like a bug).
  const barXp = after == null ? undefined : (!up && !filled && fresh != null ? Math.max(0, after - ev.xp) : after)
  return (
    <div className="xpgain">
      <div className="xpgain-amount">{t('match.xpGained', { xp: ev.xp })}</div>
      {CROWNS_ENABLED && (ev.crowns ?? 0) > 0 && <div className="xpgain-crowns"><IconCrown /> {t('match.crownsGained', { n: ev.crowns ?? 0 })}</div>}
      <LevelBar xp={barXp} />
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
