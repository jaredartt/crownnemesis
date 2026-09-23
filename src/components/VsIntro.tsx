import { useEffect, useState } from 'react'
import { Avatar } from './Avatar'
import { getHeadToHead, getMatchIntroProfiles, type HeadToHead, type MatchIntroProfile } from '../lib/api'
import { nameColorStyle } from '../lib/nameColors'
import { ACHIEVEMENTS_BY_ID } from '../lib/achievements'
import { useT } from '../lib/i18n'
import type { MatchRow, RoyalePlayerRow } from '../lib/types'

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
  // Jared: "if rematches happen... say [they have] a 1 win streak against
  // that person" -- null for a bot match (guest_id is null, see this
  // component's own header) and for two players who have never met.
  const [h2h, setH2h] = useState<HeadToHead | null>(null)

  useEffect(() => {
    let alive = true
    const ids = [match.host_id, match.guest_id].filter((x): x is string => Boolean(x))
    if (ids.length > 0) {
      getMatchIntroProfiles(ids).then((p) => { if (alive) setProfiles(p) })
    }
    return () => { alive = false }
  }, [match.host_id, match.guest_id])

  useEffect(() => {
    let alive = true
    setH2h(null)
    if (match.host_id && match.guest_id) {
      getHeadToHead(match.host_id, match.guest_id).then((r) => { if (alive) setH2h(r) })
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
        color={host?.name_color ?? null}
        side="host"
        streakText={h2h && h2h.leaderId === match.host_id && match.guest_name
          ? t('vsIntro.streak', { n: h2h.streak, name: match.guest_name }) : null}
      />
      <div className="vsintro-emblem" aria-hidden="true">VS</div>
      <Fighter
        name={match.guest_name ?? '…'}
        avatar={guest?.avatar ?? null}
        featured={guest?.featured_achievements ?? []}
        color={guest?.name_color ?? null}
        side="guest"
        streakText={h2h && match.guest_id && h2h.leaderId === match.guest_id
          ? t('vsIntro.streak', { n: h2h.streak, name: match.host_name }) : null}
      />
      <p className="vsintro-hint">{t('vsIntro.tapToSkip')}</p>
    </div>
  )
}

function Fighter({ name, avatar, featured, color, side, streakText }: {
  name: string
  avatar: string | null
  featured: string[]
  color: string | null
  side: 'host' | 'guest'
  /** "N win streak against <the other one>", already built by the caller
   *  (which has both names) -- null whenever getHeadToHead above has
   *  nothing to say, so this row of the screen just isn't there. */
  streakText?: string | null
}) {
  return (
    <div className={`vsintro-fighter ${side}`}>
      <Avatar slug={avatar} name={name} size={96} className="is-big" />
      <div className="vsintro-name" style={nameColorStyle(color)}>{name}</div>
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
      {streakText && <p className="vsintro-streak">{streakText}</p>}
    </div>
  )
}


/**
 * Royale's own opening screen -- up to four seats instead of a fixed two,
 * so unlike Fighter above (which leans host left / guest right, a shape
 * that only means something for exactly two sides) every seat here gets
 * the same plain rise-and-settle, staggered a beat apart by `--i` so they
 * don't all land in the same instant. No achievement badges (royale_players
 * is the lighter row -- see RoyalePlayerRow -- and carries no
 * featured_achievements to show), and no "VS" emblem either: a free-for-all
 * table isn't a head-to-head, so there is no "versus" to put between them.
 *
 * RoyaleMatch.tsx shows this once, at the same moment 1v1's own VsIntro
 * shows -- the instant the match exists ('deploying'), behind Get Ready --
 * and dismisses it the same way, on the timer or on the first tap or key.
 */
export function RoyaleVsIntro({ players, onDone }: {
  players: RoyalePlayerRow[]
  onDone: () => void
}) {
  const t = useT()

  useEffect(() => {
    const id = setTimeout(onDone, VS_INTRO_MS)
    window.addEventListener('keydown', onDone)
    return () => { clearTimeout(id); window.removeEventListener('keydown', onDone) }
    // Deliberately once, on mount -- see VsIntro's own identical effect.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <div className="vsintro is-royale" onPointerDown={onDone} role="status">
      {players.map((p, i) => (
        <div key={p.seat} className="vsintro-fighter is-royale" style={{ '--i': i } as React.CSSProperties}>
          <Avatar slug={p.avatar} name={p.username} size={80} className="is-big" />
          <div className="vsintro-name" style={nameColorStyle(p.name_color ?? null)}>{p.username}</div>
        </div>
      ))}
      <p className="vsintro-hint">{t('vsIntro.tapToSkip')}</p>
    </div>
  )
}
