import type { Affliction } from '../lib/effects'

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
 * Same "no JS after mount" construction as HitBurst: every particle's
 * throw is a CSS custom property, the movement is one keyframe, and the
 * compositor runs the whole thing on its own thread.
 */
const BURST_N = 9

export function StatusBurst({ kind }: { kind: Affliction }) {
  return (
    <div className={`statusburst statusburst-${kind}`} aria-hidden="true">
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
