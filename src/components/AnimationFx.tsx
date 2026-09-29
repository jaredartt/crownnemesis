import type { CSSProperties, ReactNode } from 'react'
import type { Animation } from '../lib/types'

/**
 * 0158: renders one of the five admin-tunable presets -- the shared core
 * both AdminAnimations.tsx's own sandbox preview and (once the fast-follow
 * lands, see 0158_animations.sql's header) a real match's cinematic will
 * call, so there is exactly one place that knows how an Animation row
 * turns into pixels.
 *
 * Same construction as HealBurst.tsx/StatusBurst.tsx right next to this
 * file -- a DOM div, positioned entirely by CSS custom properties, moved by
 * a shared @keyframes rule, no JS after mount, `cqw` units so it scales
 * with whatever tile it's dropped into. The one real difference: those two
 * components each hand-tune a fixed multi-stage curve (0%/18%/100% for a
 * shard, say); this one is admin-facing, so every shape here is a straight
 * start-to-end interpolation between the row's own scale_start/scale_end
 * and opacity_start/opacity_end -- an admin setting two numbers and
 * trusting the line between them beats fighting a hidden easing curve they
 * can't see or tune.
 *
 * Takes an `Animation` row, OR a plain object shaped like one (`spec`) --
 * AdminAnimations.tsx's own sandbox preview passes the unsaved draft
 * straight through so a preview always reflects exactly what's in the
 * form, never what was last saved.
 */
export type AnimationSpec = Pick<Animation,
  'shape' | 'color' | 'duration_ms' | 'particle_count' | 'spread_deg' | 'radius_px'
  | 'scale_start' | 'scale_end' | 'opacity_start' | 'opacity_end'
>

/** particle_count/spread_deg are documented (0158_animations.sql) as unused
 *  by these three shapes -- AdminAnimations.tsx's own form hides those two
 *  fields when one of these is picked, and this fan width is what beam_line
 *  draws instead: a fixed small count, not admin-tunable in v1. */
const BEAM_FAN_N: number = 5

export function AnimationFx({ spec, className, style }: {
  spec: AnimationSpec
  className?: string
  style?: CSSProperties
}) {
  const vars = {
    '--afx-color': spec.color,
    '--afx-ms': `${spec.duration_ms}ms`,
    '--afx-scale-start': spec.scale_start,
    '--afx-scale-end': spec.scale_end,
    '--afx-op-start': spec.opacity_start,
    '--afx-op-end': spec.opacity_end,
  } as CSSProperties
  const wrap = (children: ReactNode) => (
    <div className={`animfx${className ? ` ${className}` : ''}`} style={{ ...vars, ...style }} aria-hidden="true">
      {children}
    </div>
  )

  if (spec.shape === 'pulse_only') {
    return wrap(
      <i className="animfx-ring" style={{ '--afx-size': spec.radius_px * 2 } as CSSProperties} />,
    )
  }

  if (spec.shape === 'ring_pulse') {
    return wrap(
      <>
        <i className="animfx-flash" />
        <i className="animfx-ring" style={{ '--afx-size': spec.radius_px * 2 } as CSSProperties} />
      </>,
    )
  }

  if (spec.shape === 'arc_sweep') {
    return wrap(
      <i
        className="animfx-arc"
        style={{ '--afx-radius': `${spec.radius_px}cqw`, '--afx-sweep': `${spec.spread_deg}deg` } as CSSProperties}
      />,
    )
  }

  if (spec.shape === 'beam_line') {
    return wrap(
      Array.from({ length: BEAM_FAN_N }, (_, i) => {
        const spread = spec.spread_deg
        const angleDeg = BEAM_FAN_N === 1 ? 0 : (i / (BEAM_FAN_N - 1)) * spread - spread / 2
        return (
          <i
            key={i}
            className="animfx-beam"
            style={{
              '--afx-len': `${spec.radius_px}cqw`,
              '--afx-rot': `${angleDeg.toFixed(1)}deg`,
              '--d': `${i * 30}ms`,
            } as CSSProperties}
          />
        )
      }),
    )
  }

  // round_burst / diamond_burst -- HealBurst.tsx/StatusBurst.tsx's own
  // deterministic trig placement (not random, so the same animation always
  // looks the same, in the sandbox and eventually to both players), just
  // generalised to admin-tunable particle_count/spread_deg/radius_px
  // instead of each burst being its own hardcoded component.
  const n = Math.max(0, spec.particle_count)
  return wrap(
    <>
      <i className="animfx-flash" />
      {Array.from({ length: n }, (_, i) => {
        const jitter = n <= 1 ? 0 : ((i * 2.71) % 1) * (spec.spread_deg / 9) - spec.spread_deg / 18
        const angle = ((i / Math.max(1, n)) * spec.spread_deg + jitter) * (Math.PI / 180)
        const far = spec.radius_px * (0.7 + ((i * 5) % 4) * 0.1)
        return (
          <i
            key={i}
            className={spec.shape === 'diamond_burst' ? 'animfx-particle animfx-particle-diamond' : 'animfx-particle animfx-particle-round'}
            style={{
              '--dx': `${(Math.cos(angle) * far).toFixed(2)}cqw`,
              '--dy': `${(Math.sin(angle) * far).toFixed(2)}cqw`,
              '--d': `${(i % 4) * 18}ms`,
              '--sz': `${4 + ((i * 3) % 3) * 2}cqw`,
            } as CSSProperties}
          />
        )
      })}
    </>,
  )
}
