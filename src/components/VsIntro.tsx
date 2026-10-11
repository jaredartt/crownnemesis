import { useEffect, useState } from 'react'
import { Avatar, DEFAULT_AVATAR } from './Avatar'
import { Flames } from './Flames'
import { artUrl } from '../lib/art'
import { useCardsBySlug } from '../lib/useCards'
import { playHit } from '../lib/sfx'
import { getHeadToHead, getMatchIntroProfiles, type HeadToHead, type MatchIntroProfile } from '../lib/api'
import { nameColorStyle } from '../lib/nameColors'
import { ACHIEVEMENTS_BY_ID } from '../lib/achievements'
import { useT } from '../lib/i18n'
import type { MatchRow, RoyalePlayerRow } from '../lib/types'
import { AchIcon } from './AchIcon'

/** How long the screen holds before it advances on its own. Same shape as
 *  the "Defeat the king." title card this replaces (see Match.tsx's old
 *  PROCLAIM_MS): short on purpose, and any key or tap takes the rest back. */
const VS_INTRO_MS = 2600   // Royale's screen; the 1v1 one has its own timeline below

// The 1v1 VS screen (all times in ms from the moment the show starts; keep in step
// with the .vs2 keyframes in styles.css): your picture rises, the opponent's drops and
// clashes at IMPACT_MS, a flash, the VS emblem, the flames, then the names.
const IMPACT_MS = 700
const FLAMES_AT_MS = 850
const FLAMES_MS = 3000
const VS_TOTAL_MS = 5160
const READY_CAP_MS = 1500

/**
 * The very first thing a match shows: both fighters faced off, each with up
 * to three of their featured achievements underneath, and a VS between them.
 * Sits where the old "Defeat the king." title card used to -- Match.tsx shows
 * this once, at the same moment, and dismisses either on the timer or on the
 * first tap or key.
 *
 * A bot match has no second profile row -- guest_id is null whenever `bot`
 * is set -- so the right side falls back to the guest's name and avatar
 * carried on the match row itself (guest_name/guest_avatar, both set by
 * bot_identity() -- a random name and a random card-art slug, the same way
 * the bot appears everywhere else in this app) rather than a fetched
 * profile. Still no achievement badges or head-to-head streak: a bot has
 * neither.
 */
export function VsIntro({ match, pov, onDone }: { match: MatchRow; pov: 'host' | 'guest'; onDone: () => void }) {
  const t = useT()
  const cards = useCardsBySlug()
  const [profiles, setProfiles] = useState<Record<string, MatchIntroProfile>>({})
  const [profilesIn, setProfilesIn] = useState(false)
  // Jared: "if rematches happen... say [they have] a 1 win streak against
  // that person" -- null for a bot match (guest_id is null, see this
  // component's own header) and for two players who have never met.
  const [h2h, setH2h] = useState<HeadToHead | null>(null)
  // The show starts (`.is-go`) only once both pictures are in hand, so the two
  // halves never arrive empty. A hard cap keeps a slow network from holding the
  // match back: after READY_CAP_MS it starts with whatever it has.
  const [go, setGo] = useState(false)
  const [flames, setFlames] = useState(false)

  useEffect(() => {
    let alive = true
    const ids = [match.host_id, match.guest_id].filter((x): x is string => Boolean(x))
    if (ids.length > 0) {
      getMatchIntroProfiles(ids).then((p) => { if (alive) { setProfiles(p); setProfilesIn(true) } })
        .catch(() => { if (alive) setProfilesIn(true) })
    } else setProfilesIn(true)
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

  // Who is who. You are always the one rising from beneath (left on a wide screen,
  // bottom on a phone), the opponent drops in from above.
  const me = pov
  const them = pov === 'host' ? 'guest' : 'host'
  const side = (s: 'host' | 'guest') => {
    const id = s === 'host' ? match.host_id : match.guest_id
    const pr = id ? profiles[id] : null
    const slug = pr?.avatar ?? (s === 'guest' ? match.guest_avatar : null) ?? DEFAULT_AVATAR
    return {
      s,
      name: (s === 'host' ? match.host_name : match.guest_name) ?? '…',
      art: artUrl(cards.get(slug)?.art_url ?? `cards/${slug}.webp`),
      featured: pr?.featured_achievements ?? [],
      color: pr?.name_color ?? (s === 'guest' ? match.guest_name_color : null) ?? null,
    }
  }
  const mine = side(me)
  const theirs = side(them)
  const streakFor = (s: 'host' | 'guest') =>
    h2h && match.host_id && match.guest_id && h2h.leaderId === (s === 'host' ? match.host_id : match.guest_id)
      ? t('vsIntro.streak', { n: h2h.streak, name: (s === 'host' ? match.guest_name : match.host_name) ?? '' })
      : null

  // Ready = profiles are in and both pictures are decoded (or the cap hit).
  useEffect(() => {
    if (go) return
    const cap = setTimeout(() => setGo(true), READY_CAP_MS)
    if (!profilesIn) return () => clearTimeout(cap)
    let alive = true
    const load = (src: string | null) => new Promise<void>((res) => {
      if (!src) return res()
      const im = new Image()
      im.onload = () => res(); im.onerror = () => res()
      im.src = src
    })
    Promise.all([load(mine.art), load(theirs.art)]).then(() => { if (alive) setGo(true) })
    return () => { alive = false; clearTimeout(cap) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [profilesIn, mine.art, theirs.art, go])

  // Once it starts: the impact thud, the flames, and the end.
  useEffect(() => {
    if (!go) return
    const thud = setTimeout(() => playHit(0.6), IMPACT_MS)
    const fire = setTimeout(() => setFlames(true), FLAMES_AT_MS)
    const end = setTimeout(onDone, VS_TOTAL_MS)
    return () => { clearTimeout(thud); clearTimeout(fire); clearTimeout(end) }
    // Deliberately once the show starts -- onDone is a stable setState dispatch.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [go])

  useEffect(() => {
    window.addEventListener('keydown', onDone)
    return () => window.removeEventListener('keydown', onDone)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const plate = (f: ReturnType<typeof side>, cls: string) => (
    <div className={`vs2-info ${cls}`}>
      <div className="vs2-plate"><span style={nameColorStyle(f.color)}>{f.name}</span></div>
      {f.featured.length > 0 && (
        <div className="vs2-badges">
          {f.featured.map((id) => {
            const a = ACHIEVEMENTS_BY_ID.get(id)
            return a ? <span key={id} className="vs2-badge" aria-hidden="true"><AchIcon icon={a.icon} /></span> : null
          })}
        </div>
      )}
      {streakFor(f.s) && <p className="vs2-streak">{streakFor(f.s)}</p>}
    </div>
  )

  return (
    <div className={`vs2${go ? ' is-go' : ''}`} onPointerDown={onDone} role="status">
      <div className="vs2-stage">
        <div className="vs2-panel is-mine">{mine.art && <img src={mine.art} alt="" draggable={false} />}</div>
        <div className="vs2-panel is-theirs">{theirs.art && <img src={theirs.art} alt="" draggable={false} />}</div>
        {flames && <Flames ms={FLAMES_MS} />}
        <div className="vs2-flash" />
        <div className="vs2-emblem" aria-hidden="true"><span><b>VS</b></span></div>
        {plate(mine, 'is-mine')}
        {plate(theirs, 'is-theirs')}
      </div>
      <p className="vs2-hint">{t('vsIntro.tapToSkip')}</p>
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
          <Avatar slug={p.avatar} name={p.username} size={80} className="is-big" frame={p.equipped_frame} />
          <div className="vsintro-name" style={nameColorStyle(p.name_color ?? null)}>{p.username}</div>
        </div>
      ))}
      <p className="vsintro-hint">{t('vsIntro.tapToSkip')}</p>
    </div>
  )
}
