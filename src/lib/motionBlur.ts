/**
 * Motion blur, the way it is made in games when there is no per-pixel velocity buffer:
 * a camera's blur is the AVERAGE of the picture over the instant the shutter is open, so
 * a thing that moved shows smeared ALONG its path and nowhere else, and the faster it
 * went the longer the smear. A CSS `filter: blur()` cannot do that (it blurs every way
 * at once, which just looks out of focus), and an SVG directional blur is axis-only and
 * slow on Safari / phones. So the shutter is sampled by hand: a few faint copies of the
 * card that run the SAME path a few milliseconds late. While the card is fast the copies
 * trail well behind it and read as a smear; as it slows they converge underneath it and
 * vanish. Each copy is removed when its own run ends.
 *
 * The Look & feel dial (blurRate(): 0 off, 1 standard, 2 double) sets how long the smear
 * is (the gap between samples) and how visible it is. Reduce motion turns it off.
 */
import { blurRate } from './lookFeel'
import { lessMotion } from './settings'

const SAMPLES = 9
/** ms between samples at the standard setting: SAMPLES x this is the shutter. */
const STEP_MS = 6.5

function live(): { k: number; step: number; alpha: number } | null {
  const k = blurRate()
  if (k <= 0 || lessMotion()) return null
  const kk = Math.min(k, 2)
  return { k: kk, step: STEP_MS * kk, alpha: 0.3 * Math.min(kk, 1.4) }
}

/** The ghosts' opacity: strongest right behind the card, fading along the trail. */
const fade = (i: number, alpha: number) => alpha * (1 - (i - 1) / (SAMPLES + 0.5))

function spawn(el: HTMLElement, cls: string): HTMLElement | null {
  const parent = el.parentElement
  if (!parent) return null
  const g = el.cloneNode(true) as HTMLElement
  g.className = cls
  g.setAttribute('aria-hidden', 'true')
  g.removeAttribute('id')
  g.style.pointerEvents = 'none'
  parent.insertBefore(g, el)   // underneath the real card
  return g
}

/**
 * A slide: `el` is animated from (dx, dy) to where it is, over `duration` with `easing`
 * (Board.tsx plays that animation; this adds the trail to it).
 * `cls` is the class the copies get -- the slot's own, minus whatever starts animations.
 */
export function smearSlide(el: HTMLElement, dx: number, dy: number, duration: number, easing: string, cls = 'unit-slot mb-ghost') {
  const s = live()
  if (!s) return
  for (let i = 1; i <= SAMPLES; i++) {
    const g = spawn(el, cls)
    if (!g) return
    g.style.opacity = String(fade(i, s.alpha))
    const a = g.animate(
      [{ transform: `translate(${dx}px, ${dy}px)` }, { transform: 'translate(0px, 0px)' }],
      { duration, easing, delay: i * s.step, fill: 'both' },
    )
    const done = () => g.remove()
    a.finished.then(done, done)
  }
}

/**
 * A strike: the slot already carries a CSS animation (.fx-strike's lunge) that Board.tsx
 * did not start by hand, so the copies carry the same class and just begin later. `late`
 * is the lunge's own delay (the counter-blow's), which the copies keep.
 */
export function smearCss(el: HTMLElement) {
  const s = live()
  if (!s) return
  const cs = getComputedStyle(el)
  const base = parseFloat(cs.animationDelay) * (cs.animationDelay.endsWith('ms') ? 1 : 1000) || 0
  const total = base + (parseFloat(cs.animationDuration) * (cs.animationDuration.endsWith('ms') ? 1 : 1000) || 340)
  const cls = el.className.split(/\s+/).filter((c) => c === 'unit-slot' || c.startsWith('fx-strike')).join(' ') + ' mb-ghost'
  for (let i = 1; i <= SAMPLES; i++) {
    const g = spawn(el, cls)
    if (!g) return
    g.style.opacity = String(fade(i, s.alpha))
    g.style.animationDelay = `${base + i * s.step}ms`
    g.style.animationFillMode = 'backwards'
    setTimeout(() => g.remove(), total + i * s.step + 80)
  }
}
