import { FxPulse } from './FxPulse'

/**
 * Item 9, redone again -- Jared: "at any given point if a unit gets healed,
 * a green pulse animation appears on it with an animation of rapid small
 * light green rhombus coming from the center of the unit to outwards, just
 * to have something visual when someone gets healed." Replaces the earlier
 * three-rising-hearts version with the notorious pulse every affliction now
 * gets too (FxPulse, in --good) plus a burst of small light-green
 * rhombuses -- the game's own diamond shape, same shard idiom HitBurst
 * uses for a landed blow, just smaller, more numerous and quicker so a
 * stream of them reads as "rapid" rather than "an impact."
 *
 * Same construction as HitBurst/StatusBurst: every particle's throw is a
 * CSS custom property, the movement is one keyframe (`shard`, shared with
 * HitBurst), and the compositor runs the whole thing on its own thread.
 * Remounted by `key` at the call site, same convention as the others, so
 * two heals in quick succession each play their own burst.
 */
const SHARD_N = 14

export function HealBurst({ style }: { style?: React.CSSProperties }) {
  return (
    <div className="healburst" style={style} aria-hidden="true">
      <FxPulse color="var(--good)" />
      {Array.from({ length: SHARD_N }, (_, i) => {
        // Deterministic, not random -- same reason HitBurst's shards are:
        // the same heal looks the same to both players.
        const spread = ((i * 2.71) % 1) * 40 - 20
        const angle = ((i / SHARD_N) * 360 + spread) * (Math.PI / 180)
        const far = 40 + ((i * 5) % 4) * 8

        return (
          <i
            key={i}
            className="healburst-shard"
            style={{
              '--dx': `${(Math.cos(angle) * far).toFixed(2)}cqw`,
              '--dy': `${(Math.sin(angle) * far).toFixed(2)}cqw`,
              '--d': `${(i % 4) * 18}ms`,
              '--sz': `${5 + ((i * 3) % 3) * 2}cqw`,
            } as React.CSSProperties}
          />
        )
      })}
    </div>
  )
}
