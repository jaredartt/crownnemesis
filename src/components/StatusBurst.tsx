import type { Affliction } from '../lib/effects'
import { FxPulse } from './FxPulse'

/**
 * A round mini-explosion of colour, once, the instant a unit picks up an
 * affliction -- Jared: "when someone gets poisoned or burned or stunned, in
 * that very moment they just got that status effect, on the token it shows
 * like a round mini explosion of the color of the status." Sibling to
 * HitBurst (a hit's own diamond shards), deliberately drawn ROUND instead --
 * a diamond already means "damage landed" on this board, and reusing that
 * shape here would say a status application is that same kind of blow.
 * Colour matches the whole-card pulse each affliction already breathes
 * (`.unit.is-burned/-poisoned/-stunned::after` in styles.css) -- burn red,
 * poison purple, stun yellow -- so the burst and the pulse it fades into
 * read as one moment rather than two different effects taking turns.
 *
 * Jared, later: "make a notorious pulse also (the same that you use for
 * healing) of the color of that status." The flash/ring below were already
 * a quiet pulse of their own but sized and timed to the burst itself, not
 * to the whole token; FxPulse is the louder, whole-token version HealBurst
 * now carries too, reused here in `--sb-color` so the exact same
 * two-rings-plus-wash reads as "healed" in green and "afflicted" in each
 * status's own colour.
 *
 * Same "no JS after mount" construction as HitBurst: every particle's
 * throw is a CSS custom property, the movement is one keyframe, and the
 * compositor runs the whole thing on its own thread.
 */
const BURST_N = 9

/**
 * 0096: 'guard' joins burn/poison/stun -- the same notorious pulse, in
 * green, the instant a unit or a structure picks up `defending`. Jared:
 * "When a card gains defended, it also needs a pulse of green color, of
 * course, just like the other statuses." Fed by `--sb-color`, same as the
 * three afflictions -- .statusburst-guard in styles.css is the one new
 * rule that sets it, reusing `--good` rather than a fourth hardcoded green.
 *
 * 'statchange' joins them: any OTHER stat (range, move, power, ...) raised
 * or lowered at runtime -- Jared: "let's choose the color blue" for this
 * one. Fed by Board.tsx's newlyStatChanged diff, same mechanics as guard's
 * newlyDefended. .statusburst-statchange in styles.css reuses #2f80ed, the
 * game's existing Flying-role blue, rather than a fifth hardcoded one --
 * `--you`/`--you-ink` were considered and ruled out, since those carry
 * "your side" meaning that has nothing to do with a stat changing.
 */
export function StatusBurst({ kind }: { kind: Affliction | 'guard' | 'statchange' }) {
  return (
    <div className={`statusburst statusburst-${kind}`} aria-hidden="true">
      <FxPulse color="var(--sb-color)" />
      <i className="statusburst-flash" />
      <i className="statusburst-ring" />
      {Array.from({ length: BURST_N }, (_, i) => {
        // Deterministic, not random -- same reason HitBurst's shards are:
        // the same status looks the same to both players.
        const spread = ((i * 3.11) % 1) * 30 - 15
        const angle = ((i / BURST_N) * 360 + spread) * (Math.PI / 180)
        const far = 55 + ((i * 5) % 4) * 10

        return (
          <i
            key={i}
            className="statusburst-dot"
            style={{
              '--dx': `${(Math.cos(angle) * far).toFixed(2)}cqw`,
              '--dy': `${(Math.sin(angle) * far).toFixed(2)}cqw`,
              '--d': `${(i % 3) * 22}ms`,
              '--sz': `${10 + ((i * 3) % 3) * 3}cqw`,
            } as React.CSSProperties}
          />
        )
      })}
    </div>
  )
}
