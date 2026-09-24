import { useEffect, useState } from 'react'
import { lessMotion } from '../lib/settings'

/**
 * A crown appears in the middle of the screen, holds a beat, then breaks
 * apart -- Jared: "whenever a king is defeated, a crown appears in the
 * middle of the screen and animate it so that it breaks, then the pop-up
 * window of win/lose appears." Purely decorative: no board state, no
 * props, nothing to click. Both call sites (Match.tsx for 1v1,
 * RoyaleMatch.tsx for Battle Royale) mount this the instant a king actually
 * falls and hold their own results Modal behind a `setTimeout(CROWN_BREAK_MS)`
 * gated by a bit of state, the same way TurnBand.tsx owns its own
 * appear/hold/leave timing and hands the caller one constant to build a
 * lock around rather than the caller guessing at three separate numbers.
 *
 * The glyph is the game's own crown -- reused from RoyaleBoard.tsx's
 * `.rbunit-crown` royal-unit badge (a plain `♛`) rather than a new SVG/image
 * asset, per Jared's own established motif. "Breaking" is the same trick
 * `.hitburst`'s `shard` keyframes already use for a landed blow: multiple
 * copies of the one glyph, flung apart on divergent translate/rotate paths
 * and faded out, reads as "shattering" without needing real shard-shaped
 * art.
 */
const APPEAR_MS = 200
const HOLD_MS = 350
const BREAK_MS = 650
/** Exported so both call sites wait exactly this long before opening their
 *  results Modal -- see this file's own comment above. */
export const CROWN_BREAK_MS = APPEAR_MS + HOLD_MS + BREAK_MS

// Three fragments, each a copy of the same glyph flung on its own path.
// Static rather than randomised: this is a fixed piece of choreography, not
// data-driven, so there is nothing to gain from re-rolling it per match.
const PIECES: Array<{ px: string; py: string; pr: string }> = [
  { px: '-72px', py: '-64px', pr: '-55deg' },
  { px: '78px', py: '-46px', pr: '62deg' },
  { px: '2px', py: '92px', pr: '18deg' },
]

export function CrownBreak() {
  const [breaking, setBreaking] = useState(false)

  useEffect(() => {
    const id = setTimeout(() => setBreaking(true), APPEAR_MS + HOLD_MS)
    return () => clearTimeout(id)
    // Once per mount -- the caller gives this a fresh mount per king-fall
    // (no `key` needed here since it is only ever rendered for the single
    // fixed duration a fresh setTimeout(CROWN_BREAK_MS) is already gating).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <div
      className={`crownbreak${breaking ? ' is-breaking' : ''}${lessMotion() ? ' less-motion' : ''}`}
      aria-hidden="true"
    >
      <span className="crownbreak-ring" />
      <span className="crownbreak-glyph">♛</span>
      {PIECES.map((p, i) => (
        <span
          key={i}
          className="crownbreak-piece"
          style={{ '--px': p.px, '--py': p.py, '--pr': p.pr } as React.CSSProperties}
        >
          ♛
        </span>
      ))}
    </div>
  )
}
