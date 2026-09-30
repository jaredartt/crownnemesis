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

  const extra = renderBigShape(spec)
  if (extra) return wrap(extra)

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

/* ------------------------------------------------------------------------
   0187: the ten "big" shapes. Same rules as everything above -- deterministic
   (no Math.random, so an animation looks the same every time and to both
   players), DOM/SVG only, sized in `cqw` so it scales with its tile, and
   every piece carries `.animfx-x` so the reduce-motion / tutorial-loop rules
   in styles.css can reach it. Every shape also includes one `.animfx-flash`
   so that under reduce-motion (everything else hidden) a soft glow still
   marks where it would have landed.

   Timings inside a shape are fractions of duration_ms, resolved here in JS
   (a `--afx-ms` override per piece where it needs its own shorter duration),
   so the whole thing always finishes inside duration_ms -- Board.tsx keeps
   the overlay mounted for exactly the longest attached duration.
   radius_px is the "reach" of the effect in cqw: bolt length, meteor fall
   distance, pillar height, shockwave radius, and so on. */
const rnd = (i: number, k: number): number => {
  const v = Math.sin(i * 127.1 + k * 311.7) * 43758.5453
  return v - Math.floor(v)
}
const px = (n: number): string => `${n.toFixed(2)}cqw`
const ms = (n: number): string => `${Math.round(n)}ms`
const clamp = (n: number, lo: number, hi: number): number => Math.min(hi, Math.max(lo, n))
type V = CSSProperties & Record<`--${string}`, string | number>

function renderBigShape(spec: AnimationSpec): ReactNode | null {
  const T = spec.duration_ms
  const R = spec.radius_px
  const n = Math.max(0, spec.particle_count)
  const flash = (delay: number, dur: number): ReactNode => (
    <i className="animfx-flash animfx-x" style={{ animationDelay: ms(delay), '--afx-ms': ms(dur) } as V} />
  )

  switch (spec.shape) {
    // Rings racing outward, each thinner and fainter than the one before, with
    // a hard flash at the centre.
    case 'shockwave':
      return (
        <>
          {flash(0, T * 0.4)}
          {[0, 1, 2].map((i) => (
            <i
              key={i}
              className="animfx-shock animfx-x"
              style={{ '--afx-size': R * 2 * (1 - i * 0.18), '--d': ms(i * T * 0.13), '--afx-ms': ms(T * 0.74) } as V}
            />
          ))}
        </>
      )

    // A jagged bolt from above with a branch, drawn in one stroke, then
    // flickering; sparks and a flash where it lands.
    case 'lightning': {
      const pts: [number, number][] = []
      const steps = 9
      for (let i = 0; i <= steps; i++) {
        const x = i === steps ? 17 : 17 + (rnd(i, 1) - 0.5) * 17
        pts.push([x, (i / steps) * 100])
      }
      const main = pts.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ')
      const [bx, by] = pts[4]
      const branch = `${bx.toFixed(1)},${by.toFixed(1)} ${(bx + 9).toFixed(1)},${(by + 10).toFixed(1)} ${(bx + 5).toFixed(1)},${(by + 17).toFixed(1)} ${(bx + 15).toFixed(1)},${(by + 30).toFixed(1)}`
      const layers: [string, string][] = [['animfx-bolt-glow', main], ['animfx-bolt-core', main], ['animfx-bolt-glow animfx-bolt-thin', branch], ['animfx-bolt-core animfx-bolt-thin', branch]]
      return (
        <>
          {flash(T * 0.12, T * 0.5)}
          <svg className="animfx-bolt animfx-x" viewBox="0 0 34 100" style={{ '--afx-len': px(R) } as V}>
            {layers.map(([c, d], i) => (
              <polyline key={i} className={c} points={d} pathLength={1} />
            ))}
          </svg>
          {Array.from({ length: clamp(n, 0, 24) }, (_, i) => {
            const a = ((i + rnd(i, 2) * 0.6) / Math.max(1, n)) * Math.PI * 2
            const far = 10 + rnd(i, 3) * 10
            return (
              <i
                key={i}
                className="animfx-particle animfx-particle-diamond animfx-x"
                style={{
                  '--dx': px(Math.cos(a) * far), '--dy': px(Math.sin(a) * far * 0.7),
                  '--d': ms(T * 0.12), '--sz': px(1.6 + rnd(i, 4) * 1.8), '--afx-ms': ms(T * 0.6),
                } as V}
              />
            )
          })}
        </>
      )
    }

    // n tapered slashes (particle_count, 1-6) drawn one after another across the tile.
    case 'claw_slash': {
      const k = clamp(Math.round(n) || 3, 1, 6)
      return (
        <>
          {flash(T * 0.1, T * 0.6)}
          {Array.from({ length: k }, (_, i) => (
            <i
              key={i}
              className="animfx-claw animfx-x"
              style={{ '--len': px(R), '--oy': px((i - (k - 1) / 2) * R * 0.16), '--rot': `${-34 + (i - (k - 1) / 2) * 2}deg` } as V}
            >
              <b
                className="animfx-claw-in animfx-x"
                style={{ '--d': ms(i * T * 0.11), '--afx-ms': ms(T * 0.55) } as V}
              />
            </i>
          ))}
        </>
      )
    }

    // A fireball with a tail falls in from up-left; on impact: flash, ring, debris.
    case 'meteor': {
      const mx = -R * 0.55, my = -R * 0.9
      const ang = (Math.atan2(my, mx) * 180) / Math.PI
      const hit = T * 0.42
      return (
        <>
          <i
            className="animfx-meteor animfx-x"
            style={{ '--mx': px(mx), '--my': px(my), '--ang': `${ang.toFixed(1)}deg`, '--afx-ms': ms(hit) } as V}
          />
          {flash(hit, T - hit)}
          <i className="animfx-shock animfx-x" style={{ '--afx-size': R * 1.1, '--d': ms(hit), '--afx-ms': ms(T - hit) } as V} />
          {Array.from({ length: clamp(n, 0, 24) }, (_, i) => {
            const a = ((i + rnd(i, 5) * 0.5) / Math.max(1, n)) * Math.PI * 2
            const far = R * (0.22 + rnd(i, 6) * 0.22)
            return (
              <i
                key={i}
                className="animfx-particle animfx-particle-round animfx-x"
                style={{
                  '--dx': px(Math.cos(a) * far), '--dy': px(Math.sin(a) * far * 0.8),
                  '--d': ms(hit + rnd(i, 7) * 40), '--sz': px(1.8 + rnd(i, 8) * 2.4), '--afx-ms': ms(T - hit - 40),
                } as V}
              />
            )
          })}
        </>
      )
    }

    // A crown of alternating long/short rays (particle_count of them) that
    // flare out from the centre and twist a little as they fade.
    case 'starburst': {
      const k = clamp(Math.round(n) || 12, 3, 24)
      return (
        <>
          {flash(0, T * 0.6)}
          {Array.from({ length: k }, (_, i) => {
            const rot = (i / k) * (spec.spread_deg >= 359 ? 360 : spec.spread_deg) - (spec.spread_deg >= 359 ? 0 : spec.spread_deg / 2)
            return (
              <i
                key={i}
                className="animfx-ray animfx-x"
                style={{ '--len': px(R * (i % 2 ? 0.6 : 1)), '--rot': `${rot.toFixed(1)}deg`, '--rot2': `${(rot + 26).toFixed(1)}deg` } as V}
              />
            )
          })}
        </>
      )
    }

    // A column of light punches up from the tile, holds, then thins out; motes rise inside it.
    case 'light_pillar': {
      const k = clamp(n, 0, 24)
      return (
        <>
          {flash(0, T * 0.5)}
          <i className="animfx-shock animfx-x" style={{ '--afx-size': R * 0.5, '--afx-ms': ms(T * 0.6) } as V} />
          <i className="animfx-pillar animfx-x" style={{ '--afx-len': px(R) } as V} />
          {Array.from({ length: k }, (_, i) => (
            <i
              key={i}
              className="animfx-mote animfx-x"
              style={{
                '--x': px((rnd(i, 9) - 0.5) * 16), '--y0': px(4 + rnd(i, 10) * 6), '--rise': px(R * (0.5 + rnd(i, 11) * 0.5)),
                '--sway': px((rnd(i, 12) - 0.5) * 4), '--sz': px(1.2 + rnd(i, 13) * 1.6),
                '--d': ms(T * 0.12 + rnd(i, 14) * T * 0.35), '--afx-ms': ms(T * 0.5),
              } as V}
            />
          ))}
        </>
      )
    }

    // Sparks get sucked in from radius_px, then a pop where they meet.
    case 'implode': {
      const k = clamp(n, 0, 24)
      const pop = T * 0.7
      return (
        <>
          <i className="animfx-suck animfx-x" style={{ '--afx-size': R * 2, '--afx-ms': ms(pop) } as V} />
          {Array.from({ length: k }, (_, i) => {
            const a = ((i + rnd(i, 15) * 0.5) / Math.max(1, k)) * Math.PI * 2
            const far = R * (0.7 + rnd(i, 16) * 0.3)
            return (
              <i
                key={i}
                className="animfx-implode animfx-x"
                style={{
                  '--dx': px(Math.cos(a) * far), '--dy': px(Math.sin(a) * far),
                  '--d': ms(rnd(i, 17) * T * 0.15), '--sz': px(2 + rnd(i, 18) * 2.6), '--afx-ms': ms(pop - T * 0.05),
                } as V}
              />
            )
          })}
          {flash(pop, T - pop)}
          <i className="animfx-shock animfx-x" style={{ '--afx-size': R * 0.7, '--d': ms(pop), '--afx-ms': ms(T - pop) } as V} />
        </>
      )
    }

    // Motes spiral outward/upward round the tile (spread_deg x2 = total turn) inside two swirling arcs.
    case 'whirlwind': {
      const k = clamp(n, 0, 24)
      const turn = spec.spread_deg * 2
      return (
        <>
          {flash(0, T * 0.5)}
          {[0, 1].map((i) => (
            <i
              key={i}
              className="animfx-swirl animfx-x"
              style={{ '--afx-size': R * (1.5 - i * 0.55), '--turn': `${turn * (i ? -0.8 : 1)}deg`, '--d': ms(i * T * 0.08) } as V}
            />
          ))}
          {Array.from({ length: k }, (_, i) => (
            <i
              key={i}
              className="animfx-orbit animfx-x"
              style={{ '--a0': `${((i / Math.max(1, k)) * 360).toFixed(1)}deg`, '--turn': `${turn}deg`, '--d': ms(rnd(i, 19) * T * 0.15), '--afx-ms': ms(T * 0.85) } as V}
            >
              <b
                className="animfx-orbit-dot animfx-x"
                style={{ '--r': px(R * (0.55 + rnd(i, 20) * 0.45)), '--lift': px(R * (0.1 + rnd(i, 21) * 0.35)), '--sz': px(2.4 + rnd(i, 22) * 2.4), '--d': ms(rnd(i, 19) * T * 0.15), '--afx-ms': ms(T * 0.85) } as V}
              />
            </i>
          ))}
        </>
      )
    }

    // Embers drifting up from the tile -- the gentle one; good for buffs/fire.
    case 'rising_sparks': {
      const k = clamp(n, 0, 24)
      return (
        <>
          {flash(0, T * 0.45)}
          {Array.from({ length: k }, (_, i) => (
            <i
              key={i}
              className="animfx-mote animfx-x"
              style={{
                '--x': px((rnd(i, 23) - 0.5) * R * 0.55), '--y0': px(6 + rnd(i, 24) * 10), '--rise': px(R * (0.55 + rnd(i, 25) * 0.45)),
                '--sway': px((rnd(i, 26) - 0.5) * 10), '--sz': px(2.2 + rnd(i, 27) * 2.6),
                '--d': ms(rnd(i, 28) * T * 0.5), '--afx-ms': ms(T * 0.5),
              } as V}
            />
          ))}
        </>
      )
    }

    // Glowing fissures split the tile outward from the centre; rubble hops off them.
    case 'ground_crack': {
      const cracks = 7
      const lines: { d: string; delay: number }[] = []
      for (let c = 0; c < cracks; c++) {
        const base = (c / cracks) * Math.PI * 2 + (rnd(c, 30) - 0.5) * 0.5
        const pt = (r: number, a: number, wob: number): string => {
          const ox = Math.cos(a + Math.PI / 2) * wob
          const oy = Math.sin(a + Math.PI / 2) * wob
          return `${(Math.cos(a) * r + ox).toFixed(1)},${(Math.sin(a) * r + oy).toFixed(1)}`
        }
        const pts = [0, 9, 18, 28, 38, 48].map((r, j) => pt(r, base, j === 0 ? 0 : (rnd(c * 7 + j, 31) - 0.5) * 8))
        lines.push({ d: pts.join(' '), delay: rnd(c, 32) * T * 0.1 })
        if (c % 2 === 0) {
          const a2 = base + (c % 4 === 0 ? 0.6 : -0.6)
          lines.push({ d: [pt(18, base, 0), pt(26, a2, 2), pt(34, a2, -2), pt(42, a2, 1)].join(' '), delay: T * 0.12 + rnd(c, 33) * T * 0.08 })
        }
      }
      const k = clamp(n, 0, 24)
      return (
        <>
          {flash(0, T * 0.45)}
          <i className="animfx-shock animfx-x" style={{ '--afx-size': R * 0.9, '--afx-ms': ms(T * 0.55) } as V} />
          <svg className="animfx-crack animfx-x" viewBox="-50 -50 100 100" style={{ '--afx-len': px(R) } as V}>
            {['animfx-crack-base', 'animfx-crack-glow', 'animfx-crack-core'].flatMap((cls) =>
              lines.map((l, i) => (
                <polyline key={`${cls}-${i}`} className={cls} points={l.d} pathLength={1} style={{ '--d': ms(l.delay) } as V} />
              )),
            )}
          </svg>
          {Array.from({ length: k }, (_, i) => {
            const a = ((i + rnd(i, 34) * 0.7) / Math.max(1, k)) * Math.PI * 2
            const far = R * (0.15 + rnd(i, 35) * 0.3)
            return (
              <i
                key={i}
                className="animfx-shard animfx-x"
                style={{
                  '--dx': px(Math.cos(a) * far), '--dy': px(-(5 + rnd(i, 36) * 12)),
                  '--rot': `${Math.round((rnd(i, 37) - 0.5) * 360)}deg`, '--sz': px(1.6 + rnd(i, 38) * 2.4),
                  '--d': ms(T * 0.08 + rnd(i, 39) * T * 0.1), '--afx-ms': ms(T * 0.62),
                } as V}
              />
            )
          })}
        </>
      )
    }

    default:
      return null
  }
}
