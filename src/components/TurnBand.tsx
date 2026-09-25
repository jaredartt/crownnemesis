import { useEffect, useState } from 'react'
import { Avatar } from './Avatar'
import { lessMotion } from '../lib/settings'
import { useT } from '../lib/i18n'

/**
 * "Each start of a turn, [show] a black band in the middle of the screen
 * stating whose turn it is... and while those bands are there, no player
 * can actually do anything to modify the board" -- Jared, for every mode:
 * 1v1 and Royale, bot and online alike. One component so both call sites
 * (Match.tsx, RoyaleMatch.tsx) can't quietly drift into two different
 * bands with two different timings.
 *
 * Jared, this round: drop the naming entirely ("le toca a {name}") for
 * "Tu turno"/"Turno del oponente" -- "Your turn"/"Opponent's turn" -- and
 * colour the band itself to match: blue (--you) on your own turn, red
 * (--foe) on anyone else's, in place of the flat black every turn used to
 * get. Simpler to read at a glance than a name you have to parse, and the
 * colour is the same blue/red the board already uses for "yours" vs "the
 * other side" everywhere else. The avatar stays -- still useful in Battle
 * Royale, where "anyone else's" can be one of three different people, so
 * the FACE is still how you tell which. Not the player's own name-colour
 * pick, though: that only ever coloured the NAME this band used to show,
 * and there is no name left here to colour.
 *
 * Timing is entirely internal and entirely OWNED here -- a caller mounts
 * this with `key={turnKey}` (a value that changes every new turn, e.g.
 * `${turn}:${turnNumber}`) so React remounts rather than re-props it, plays
 * the appear/hold/leave sequence once, then calls `onDone` -- which is the
 * caller's cue to drop whatever lock it raised on `onSelect`/board clicks.
 * `TURN_BAND_MS` is exported so a caller can size that lock to the exact
 * same window without duplicating the three numbers that make it up.
 */
const APPEAR_MS = 260
const HOLD_MS = 900
const LEAVE_MS = 220
export const TURN_BAND_MS = APPEAR_MS + HOLD_MS + LEAVE_MS

export function TurnBand({ name, avatarSlug, isMine, onDone }: {
  name: string
  avatarSlug: string | null
  /** Whose turn this actually is: true colours the band blue and reads
   *  "Your turn", false colours it red and reads "Opponent's turn". A
   *  spectator (no side of their own) never sees this component's caller
   *  pass true, so they see every turn read as "Opponent's turn" -- an
   *  acceptable simplification, not a bug, for a feature about telling
   *  a PLAYER whether to act. */
  isMine: boolean
  onDone: () => void
}) {
  const t = useT()
  const [leaving, setLeaving] = useState(false)

  useEffect(() => {
    const leaveAt = setTimeout(() => setLeaving(true), APPEAR_MS + HOLD_MS)
    const doneAt = setTimeout(onDone, TURN_BAND_MS)
    return () => { clearTimeout(leaveAt); clearTimeout(doneAt) }
    // Once per mount -- the caller remounts this with a fresh `key` for
    // every new turn rather than re-rendering it in place, so there is no
    // stale-closure risk in only running this once.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <div
      className={`turnband ${isMine ? 'is-mine' : 'is-theirs'}${leaving ? ' is-leaving' : ''}${lessMotion() ? ' less-motion' : ''}`}
      role="status"
      aria-live="polite"
    >
      <Avatar slug={avatarSlug} name={name} size={40} className="turnband-face" />
      <span className="turnband-text">
        {t(isMine ? 'match.yourTurn' : 'match.turnBandOpponent')}
      </span>
    </div>
  )
}
