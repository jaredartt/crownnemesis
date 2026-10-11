import { useEffect, useRef } from 'react'

/**
 * A fire along the bottom of its container, drawn on a canvas: warm particles
 * (white-yellow at birth, orange, then red, then gone) rising with a little
 * sway, blended additively so overlaps burn brighter. It spawns for `ms`, lets
 * the last particles die out, and fades with them -- nothing to clean up.
 *
 * Used under the VS emblem on the match-start screen. With reduced motion on
 * it draws nothing: the screen is complete without it.
 */
interface P { x: number; y: number; vx: number; vy: number; life: number; age: number; r: number; seed: number }

export function Flames({ ms = 3000 }: { ms?: number }) {
  const ref = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const cv = ref.current
    if (!cv) return
    const root = document.documentElement
    if (root.dataset.reduceMotion === '1' || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const ctx = cv.getContext('2d')
    if (!ctx) return

    const dpr = Math.min(2, window.devicePixelRatio || 1)
    let w = 0, h = 0
    const fit = () => {
      const r = cv.getBoundingClientRect()
      w = Math.max(1, r.width); h = Math.max(1, r.height)
      cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr)
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    }
    fit()

    const ps: P[] = []
    const t0 = performance.now()
    let last = t0
    let raf = 0
    const rand = (a: number, b: number) => a + Math.random() * (b - a)

    const spawn = (n: number) => {
      for (let i = 0; i < n; i++) {
        // Bell-shaped across the width: more fire in the middle, under the emblem.
        const bell = (Math.random() + Math.random() + Math.random()) / 3
        const scale = Math.min(w, h * 1.4) / 700
        ps.push({
          x: bell * w, y: h + rand(0, 20),
          vx: rand(-25, 25) * scale, vy: -rand(160, 420) * (h / 700),
          life: rand(0.8, 1.7), age: 0, r: rand(38, 96) * Math.max(0.6, scale), seed: Math.random() * 10,
        })
      }
    }

    const frame = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000)
      last = now
      const el = now - t0
      if (el < ms) spawn(Math.round(dt * 150))
      ctx.clearRect(0, 0, w, h)
      ctx.globalCompositeOperation = 'lighter'

      // The glow the fire stands in: a low warm wash that follows the same fade.
      const fade = el < ms ? 1 : Math.max(0, 1 - (el - ms) / 700)
      const g = ctx.createLinearGradient(0, h, 0, h * 0.55)
      g.addColorStop(0, `rgba(255,120,30,${0.55 * fade})`)
      g.addColorStop(1, 'rgba(255,60,20,0)')
      ctx.fillStyle = g
      ctx.fillRect(0, h * 0.55, w, h * 0.45)

      for (let i = ps.length - 1; i >= 0; i--) {
        const p = ps[i]
        p.age += dt
        const k = p.age / p.life
        if (k >= 1) { ps.splice(i, 1); continue }
        p.x += (p.vx + Math.sin(now / 180 + p.seed) * 38) * dt
        p.y += p.vy * dt
        p.vy *= 0.992
        const rad = p.r * (1 - k * 0.55)
        // white-yellow -> orange -> red as it ages
        const col = k < 0.25 ? '255,225,120' : k < 0.6 ? '255,140,40' : '225,50,30'
        const a = Math.pow(1 - k, 1.3) * 0.5
        const rg = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, rad)
        rg.addColorStop(0, `rgba(${col},${a})`)
        rg.addColorStop(1, `rgba(${col},0)`)
        ctx.fillStyle = rg
        ctx.beginPath(); ctx.arc(p.x, p.y, rad, 0, Math.PI * 2); ctx.fill()
      }
      if (el < ms || ps.length > 0) raf = requestAnimationFrame(frame)
      else ctx.clearRect(0, 0, w, h)
    }
    raf = requestAnimationFrame(frame)
    const ro = new ResizeObserver(fit)
    ro.observe(cv)
    return () => { cancelAnimationFrame(raf); ro.disconnect() }
  }, [ms])

  return <canvas ref={ref} className="vs2-flames" aria-hidden="true" />
}
