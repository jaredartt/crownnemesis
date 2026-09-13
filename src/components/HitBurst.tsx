/**
 * A burst of rhombuses where a blow landed.
 *
 * Diamonds and not sparks or dust, because a diamond is already this game's
 * shape: the five marks on a unit are diamonds, and so is the logo. Twelve of
 * them, thrown outward on a ring with the angle, the distance and the delay
 * varied per particle -- an even ring reads as a mechanism and a scattered one
 * reads as an impact.
 *
 * Everything is a CSS custom property on the element and the movement is one
 * keyframe, so the whole burst is twelve transforms the compositor can take on
 * its own. No JavaScript runs after the mount, and the burst is remounted by
 * `key` rather than restarted, which is what makes two blows in quick
 * succession play twice instead of once.
 */
const BURST_N = 12

export function HitBurst() {
  return (
    <div className="hitburst" aria-hidden="true">
      {Array.from({ length: BURST_N }, (_, i) => {
        // Deterministic, not random: the same blow looks the same to both
        // players, which matters the day somebody records one.
        const spread = ((i * 2.399) % 1) * 26 - 13        // degrees off the spoke
        const angle = ((i / BURST_N) * 360 + spread) * (Math.PI / 180)
        const far = 42 + ((i * 7) % 5) * 9                // cqw of the box

        // The direction is baked into an OFFSET rather than into a rotation,
        // and that is the whole reason this is a rhombus and not a burst of
        // tilted squares: `rotate()` would turn the shape as well as the
        // throw, and a diamond spun thirty-seven degrees is a square. Every
        // shard keeps the same upright rhombus and simply goes somewhere
        // different.
        //
        // Container-query units, NOT per cent: a percentage inside translate
        // is a percentage of the SHARD, which is a dozen pixels across, so
        // the first version threw every piece ten pixels and the burst came
        // out as one blob. cqw is a percentage of the burst's box -- the
        // token, or the duel panel -- which is what was meant.
        return (
          <i
            key={i}
            style={{
              '--dx': `${(Math.cos(angle) * far).toFixed(2)}cqw`,
              '--dy': `${(Math.sin(angle) * far).toFixed(2)}cqw`,
              '--d': `${(i % 4) * 26}ms`,
              '--sz': `${8 + ((i * 3) % 4) * 2}cqw`,
            } as React.CSSProperties}
          />
        )
      })}
    </div>
  )
}
