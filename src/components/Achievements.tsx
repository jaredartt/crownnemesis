import { useEffect, useState } from 'react'
import { getUnlockedAchievements, setFeaturedAchievements } from '../lib/api'
import { ACHIEVEMENTS, achievementProgress } from '../lib/achievements'
import type { Profile } from '../lib/types'
import { useT } from '../lib/i18n'

/**
 * Every achievement in the catalog, unlocked ones lit up and clickable,
 * locked ones greyed out with how far off they are. Tapping an unlocked one
 * toggles it into your three featured -- tapping a featured one drops it.
 *
 * The unlocked set is fetched fresh here rather than trusted from `profile`,
 * because `profile` carries the four raw counters (for the progress numbers)
 * but never the unlock rows themselves -- those are their own table, read
 * once when this section mounts. The server is what actually decides
 * "have you unlocked this": set_featured_achievements re-checks it, so a
 * stale local set can only ever show a badge as locked a beat longer than it
 * should, never let you feature one you have not earned.
 */
export function Achievements({ profile, onChanged }: {
  profile: Profile
  onChanged: (patch: Partial<Profile>) => void
}) {
  const t = useT()
  const [unlocked, setUnlocked] = useState<Set<string> | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const featured = profile.featured_achievements ?? []

  useEffect(() => {
    let alive = true
    getUnlockedAchievements(profile.id).then((ids) => { if (alive) setUnlocked(new Set(ids)) })
    return () => { alive = false }
  }, [profile.id])

  async function toggleFeature(id: string) {
    if (!unlocked?.has(id) || busy) return
    setErr(null)
    const isFeatured = featured.includes(id)
    if (!isFeatured && featured.length >= 3) {
      setErr(t('achievements.featureLimit'))
      setTimeout(() => setErr(null), 3000)
      return
    }
    const next = isFeatured ? featured.filter((x) => x !== id) : [...featured, id]
    setBusy(id)
    onChanged({ featured_achievements: next })       // optimistic: it is one tap
    try {
      await setFeaturedAchievements(next)
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
      onChanged({ featured_achievements: featured })  // revert
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="ach">
      <h3 className="pf-title">{t('achievements.title')}</h3>
      <p className="muted tiny">{t('achievements.featureHint')}</p>
      <div className="ach-grid">
        {ACHIEVEMENTS.map((a) => {
          const isUnlocked = unlocked?.has(a.id) ?? false
          const isFeatured = featured.includes(a.id)
          const progress = achievementProgress(a, profile)
          const sub = isFeatured
            ? t('achievements.featured')
            : isUnlocked
              ? ' '
              : progress
                ? t('achievements.progress', {
                    current: Math.min(progress.current, progress.threshold),
                    threshold: progress.threshold,
                  })
                : t('achievements.locked')
          return (
            <button
              key={a.id}
              type="button"
              className={`ach-badge${isUnlocked ? ' is-unlocked' : ' is-locked'}${isFeatured ? ' is-featured' : ''}`}
              disabled={!isUnlocked || busy === a.id}
              aria-pressed={isFeatured}
              onClick={() => toggleFeature(a.id)}
              title={t(a.descKey, { n: a.threshold })}
            >
              {isFeatured && <span className="ach-star" aria-hidden="true">★</span>}
              <span className="ach-icon" aria-hidden="true">{a.icon}</span>
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
