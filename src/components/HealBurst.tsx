/**
 * Item 9: the healed status effect. The other four (burn/poison/stun/
 * defended) are persistent while their affliction holds and live as pure
 * CSS on `.unit.is-burned` etc. in styles.css -- there is no unit state for
 * "just healed" to hang a class on, so this one is a one-shot burst
 * instead, the same shape HitBurst.tsx already uses for a landed blow.
 *
 * Three small hearts, staggered, rising and fading over ~1.2s -- pure CSS
 * shape (two circles plus a rotated square, the standard technique), no
 * external art, matching how HitBurst's rhombuses are drawn. Remount by
 * `key` at the call site, same convention as HitBurst, so two heals in
 * quick succession each play their own burst rather than the second being
 * ignored as an unchanged subtree.
 */
const HEART_N = 3

export function HealBurst({ style }: { style?: React.CSSProperties }) {
  return (
    <div className="healburst" style={style} aria-hidden="true">
      {Array.from({ length: HEART_N }, (_, i) => (
        <i
          key={i}
          style={{
            '--hd': `${i * 140}ms`,
            '--hx': `${(i - 1) * 9}cqmin`,
          } as React.CSSProperties}
        />
      ))}
    </div>
  )
}
