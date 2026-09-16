import { useEffect, useState } from 'react'
import { Avatar } from './Avatar'
import { getMatchIntroProfiles, type MatchIntroProfile } from '../lib/api'
import { ACHIEVEMENTS_BY_ID } from '../lib/achievements'
import { useT } from '../lib/i18n'
import type { MatchRow } from '../lib/types'

/** How long the screen holds before it advances on its own. Same shape as
 *  the "Defeat the king." title card this replaces (see Match.tsx's old
 *  PROCLAIM_MS): short on purpose, and any key or tap takes the rest back. */
const VS_INTRO_MS = 2600

/**
 * The very first thing a match shows: both fighters faced off, each with up
 * to three of their featured achievements underneath, and a VS between them.
 * Sits where the old "Defeat the king." title card used to -- Match.tsx shows
 * this once, at the same moment, and dismisses either on the timer or on the
 * first tap or key.
 *
 * A bot match has no second profile row -- guest_id is null whenever `bot`
 * is set -- so the right side falls back to the guest's name (already a
 * presentable label like "SHARP", see bot_name() in create_bot_match) with a
 * plain placeholder avatar and no badges, the same way the bot appears
 * everywhere else in this app.
 */
export function VsIntro({ match, onDone }: { match: MatchRow; onDone: () => void }) {
  const t = useT()
  const [profiles, setProfiles] = useState<Record<string, MatchIntroProfile>>({})

  useEffect(() => {
    let alive = true
    const ids = [match.host_id, match.guest_id].filter((x): x is string => Boolean(x))
    if (ids.length > 0) {
      getMatchIntroProfiles(ids).then((p) => { if (alive) setProfiles(p) })
    }
    return () => { alive = false }
  }, [match.host_id, match.guest_id])

  useEffect(() => {
    const id = setTimeout(onDone, VS_INTRO_MS)
    window.addEventListener('keydown', onDone)
    return () => { clearTimeout(id); window.removeEventListener('keydown', onDone) }
    // Deliberately once, on mount -- see Match.tsx's identical PROCLAIM_MS
    // effect, which this one is copied from. onDone is a stable setState
    // dispatch either way, so a stale closure here calls the same function.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const host = profiles[match.host_id]
  const guest = match.guest_id ? profiles[match.guest_id] : null

  return (
    <div className="vsintro" onPointerDown={onDone} role="status">
      <Fighter
        name={match.host_name}
        avatar={host?.avatar ?? null}
        featured={host?.featured_achievements ?? []}
        side="host"
      />
      <div className="vsintro-emblem" aria-hidden="true">VS</div>
      <Fighter
        name={match.guest_name ?? '…'}
        avatar={guest?.avatar ?? null}
        featured={guest?.featured_achievements ?? []}
        side="guest"
      />
      <p className="vsintro-hint">{t('vsIntro.tapToSkip')}</p>
    </div>
  )
}

function Fighter({ name, avatar, featured, side }: {
  name: string
  avatar: string | null
  featured: string[]
  side: 'host' | 'guest'
}) {
  return (
    <div className={`vsintro-fighter ${side}`}>
      <Avatar slug={avatar} name={name} size={96} className="is-big" />
      <div className="vsintro-name">{name}</div>
      {featured.length > 0 && (
        <div className="vsintro-badges">
          {featured.map((id) => {
            const a = ACHIEVEMENTS_BY_ID.get(id)
            return a ? (
              <span key={id} className="vsintro-badge" aria-hidden="true">{a.icon}</span>
            ) : null
          })}
        </div>
      )}
    </div>
  )
}
