import { useEffect, useState } from 'react'
import { getUnlockedAchievements, setFeaturedAchievements } from '../lib/api'
import { ACHIEVEMENTS, ACHIEVEMENTS_BY_ID, achievementProgress } from '../lib/achievements'
import type { Profile } from '../lib/types'
import { useT } from '../lib/i18n'
import { AchIcon } from './AchIcon'
import { Ti } from './Ti'

/**
 * Your three featured achievements, as three slots; tapping a slot opens the
 * picker (every achievement, unlocked ones selectable, locked ones greyed with
 * how far off they are). Featuring is validated by the server
 * (set_featured_achievements re-checks the unlock), so a stale local set can
 * only ever show a badge as locked a beat longer than it should.
 */
export function useUnlockedAchievements(userId: string): Set<string> | null {
  const [unlocked, setUnlocked] = useState<Set<string> | null>(null)
  useEffect(() => {
    let alive = true
    getUnlockedAchievements(userId).then((ids) => { if (alive) setUnlocked(new Set(ids)) })
    return () => { alive = false }
  }, [userId])
  return unlocked
}

export function AchievementSlots({ profile, onOpen }: { profile: Profile; onOpen: (slot: number) => void }) {
  const t = useT()
  const featured = profile.featured_achievements ?? []
  return (
    <div className="ach-slots">
      {[0, 1, 2].map((i) => {
        const a = featured[i] ? ACHIEVEMENTS_BY_ID.get(featured[i]) : undefined
        return (
          <button key={i} type="button" className={`ach-slot${a ? ' is-filled' : ''}`} onClick={() => onOpen(i)}
                  title={a ? t(a.descKey, { n: a.threshold }) : t('profile.emptySlot')} aria-label={a ? t(a.nameKey, { n: a.threshold }) : t('profile.emptySlot')}>
            {a ? (
              <>
                <span className="ach-icon" aria-hidden="true"><AchIcon icon={a.icon} /></span>
                <span className="ach-name">{t(a.nameKey, { n: a.threshold })}</span>
              </>
            ) : <span className="ach-plus" aria-hidden="true">+</span>}
          </button>
        )
      })}
    </div>
  )
}

export function AchievementPicker({ profile, slot, unlocked, onChanged, onDone }: {
  profile: Profile
  slot: number
  unlocked: Set<string> | null
  onChanged: (patch: Partial<Profile>) => void
  onDone: () => void
}) {
  const t = useT()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const featured = profile.featured_achievements ?? []

  async function save(next: string[]) {
    setBusy(true); setErr(null)
    onChanged({ featured_achievements: next })            // optimistic
    try { await setFeaturedAchievements(next); onDone() }
    catch (e) { setErr((e as Error).message.replace(/^.*?:\s*/, '')); onChanged({ featured_achievements: featured }) }
    finally { setBusy(false) }
  }

  function place(id: string) {
    // Three fixed slots; the chosen one leaves any slot it was already in.
    const slots: (string | null)[] = [0, 1, 2].map((i) => featured[i] ?? null).map((x) => (x === id ? null : x))
    slots[slot] = id
    void save(slots.filter((x): x is string => Boolean(x)))
  }
  function clear() {
    void save(featured.filter((_, i) => i !== slot))
  }

  return (
    <div className="ach">
      <p className="muted tiny ach-hint">{t('achievements.featureHint')}</p>
      {featured[slot] && (
        <button type="button" className="btn small ghost" disabled={busy} onClick={clear}>{t('profile.clearSlot')}</button>
      )}
      <div className="ach-grid">
        {ACHIEVEMENTS.map((a) => {
          const isUnlocked = unlocked?.has(a.id) ?? false
          const here = featured[slot] === a.id
          const elsewhere = !here && featured.includes(a.id)
          const progress = achievementProgress(a, profile)
          const sub = here ? t('achievements.featured')
            : isUnlocked ? (elsewhere ? t('achievements.featured') : ' ')
            : progress ? t('achievements.progress', { current: Math.min(progress.current, progress.threshold), threshold: progress.threshold })
            : t('achievements.locked')
          return (
            <button
              key={a.id} type="button"
              className={`ach-badge${isUnlocked ? ' is-unlocked' : ' is-locked'}${here ? ' is-featured' : ''}`}
              disabled={!isUnlocked || busy} aria-pressed={here}
              onClick={() => place(a.id)}
              title={t(a.descKey, { n: a.threshold })}
            >
              {(here || elsewhere) && <span className="ach-star" aria-hidden="true"><Ti name="star" filled size="1em" /></span>}
              <span className="ach-icon" aria-hidden="true"><AchIcon icon={a.icon} /></span>
              <span className="ach-name">{t(a.nameKey, { n: a.threshold })}</span>
              <span className="ach-sub">{sub}</span>
            </button>
          )
        })}
      </div>
      {err && <p className="error">{err}</p>}
    </div>
  )
}
