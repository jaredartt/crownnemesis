import { useEffect, useState } from 'react'
import { Avatar } from './Avatar'
import { nameColorStyle } from '../lib/nameColors'
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

/** Splits an i18n template on its one `{name}` token, so the name itself
 *  can be rendered as its own coloured element while everything around it
 *  still comes from the translated string, IN WHATEVER ORDER that language
 *  puts it -- es.json's own "le toca a {name}" puts the name last, en.json's
 *  "{name}'s turn" puts it first, and this doesn't care which. */
function splitOnName(template: string): [string, string] {
  const i = template.indexOf('{name}')
  if (i === -1) return [template, '']
  return [template.slice(0, i), template.slice(i + '{name}'.length)]
}

export function TurnBand({ name, avatarSlug, color, onDone }: {
  name: string
  avatarSlug: string | null
  /** A player's own name-color pick (0060) -- null/undefined for a bot,
   *  which has none, and nameColorStyle already treats that as "leave the
   *  default text colour alone" rather than forcing one. */
  color: string | null | undefined
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

  const [before, after] = splitOnName(t('match.turnBand'))

  return (
    <div
      className={`turnband${leaving ? ' is-leaving' : ''}${lessMotion() ? ' less-motion' : ''}`}
      role="status"
      aria-live="polite"
    >
      <Avatar slug={avatarSlug} name={name} size={40} className="turnband-face" />
      <span className="turnband-text">
        {before}
        <b style={nameColorStyle(color)}>{name}</b>
        {after}
      </span>
    </div>
  )
}
