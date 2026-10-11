/**
 * The interface noise, synthesised rather than shipped.
 *
 * Two layers. The interface layer -- a click and a hover -- is delegated from
 * the document by attachUiSounds, so a new button is audible without anybody
 * remembering to make it so. The battle layer below is called by name from the
 * board, because those sounds have to land on the frame the animation lands
 * on, and only the board knows when that is. Both are an oscillator (or a
 * filtered hiss) and an envelope.
 * No files: nothing to download, nothing to license, and "make them vary" is
 * a random number rather than a folder of near-identical wavs. Each play
 * detunes a little and shortens or lengthens a little, so a row of buttons
 * does not sound like a machine.
 *
 * The context is created on the first real gesture, because a browser will
 * not let it start before one, and a suspended context that nobody resumes is
 * how you end up with silence you cannot debug.
 */
import { getSettings } from './settings'

let ctx: AudioContext | null = null
let bus: GainNode | null = null

function audio(): AudioContext | null {
  if (typeof window === 'undefined') return null
  if (!ctx) {
    const AC = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!AC) return null
    ctx = new AC()
    bus = ctx.createGain()
    // An exchange can fire four voices inside half a second -- a blow, a
    // burn, a counter and a body falling. Left alone they add up and clip,
    // which is the one thing that makes synthesised audio sound cheap.
    const squash = ctx.createDynamicsCompressor()
    squash.threshold.setValueAtTime(-18, ctx.currentTime)
    squash.ratio.setValueAtTime(6, ctx.currentTime)
    bus.connect(squash)
    squash.connect(ctx.destination)
  }
  if (ctx.state === 'suspended') void ctx.resume()
  return ctx
}

/** A note: one oscillator, one envelope, gone in under a fifth of a second. */
function blip(freq: number, ms: number, peak: number, type: OscillatorType) {
  const level = getSettings().sfx
  if (level <= 0) return
  const c = audio()
  if (!c || !bus) return

  const t = c.currentTime
  const osc = c.createOscillator()
  const env = c.createGain()
  osc.type = type
  osc.frequency.setValueAtTime(freq, t)
  // A touch of downward drift. Flat pitch reads as a beep; a falling one
  // reads as something being pressed.
  osc.frequency.exponentialRampToValueAtTime(freq * 0.82, t + ms / 1000)

  env.gain.setValueAtTime(0.0001, t)
  env.gain.exponentialRampToValueAtTime(peak * level, t + 0.006)
  env.gain.exponentialRampToValueAtTime(0.0001, t + ms / 1000)

  osc.connect(env); env.connect(bus)
  osc.start(t)
  osc.stop(t + ms / 1000 + 0.02)
}

const vary = (n: number, spread: number) => n * (1 + (Math.random() * 2 - 1) * spread)

export function playClick() {
  blip(vary(660, 0.06), vary(120, 0.15), 0.16, 'triangle')
}

export function playHover() {
  blip(vary(1180, 0.08), vary(58, 0.2), 0.05, 'sine')
}

/**
 * One pair of listeners for the whole app, delegated from the document.
 *
 * Wiring a sound into every button is a change to every button and a thing to
 * forget on the next one. This asks the event where it came from instead.
 */
export function attachUiSounds() {
  const HIT = 'button, [role="button"], a[href], .mtile, .rtile, .chapter, .modecard'
  let last: Element | null = null

  const over = (e: PointerEvent) => {
    const el = (e.target as Element | null)?.closest?.(HIT) ?? null
    if (!el || el === last) return
    last = el
    if (!(el as HTMLButtonElement).disabled) playHover()
  }
  const out = (e: PointerEvent) => {
    if (!(e.relatedTarget as Element | null)?.closest?.(HIT)) last = null
  }
  const down = (e: PointerEvent) => {
    const el = (e.target as Element | null)?.closest?.(HIT)
    if (el && !(el as HTMLButtonElement).disabled) playClick()
  }

  document.addEventListener('pointerover', over)
  document.addEventListener('pointerout', out)
  document.addEventListener('pointerdown', down)
  return () => {
    document.removeEventListener('pointerover', over)
    document.removeEventListener('pointerout', out)
    document.removeEventListener('pointerdown', down)
  }
}

/* ---------- battle -------------------------------------------------------- */

/**
 * The battle set is built out of two primitives instead of eleven hand-written
 * functions: a pitched `tone` and a filtered `noise`. Everything percussive in
 * the game -- a blow, a chop, a footfall, a parry -- is the same one second of
 * white noise heard through a different filter sweep, which is why they sound
 * like they belong to one game rather than to one library each.
 */

let hiss: AudioBuffer | null = null

/** One second of white noise, made once and reused. */
function noiseBuffer(c: AudioContext): AudioBuffer {
  if (hiss) return hiss
  const buf = c.createBuffer(1, c.sampleRate, c.sampleRate)
  const d = buf.getChannelData(0)
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1
  hiss = buf
  return buf
}

interface ToneOpts {
  freq: number
  /** Pitch at the end. Defaults to a small fall -- flat pitch reads as a beep. */
  to?: number
  ms: number
  peak: number
  type?: OscillatorType
  /** Seconds from now. How an arpeggio and a delayed counter are written. */
  delay?: number
  /** Attack, seconds. Longer is a swell, shorter is a strike. */
  attack?: number
}

function tone({ freq, to, ms, peak, type = 'sine', delay = 0, attack = 0.006 }: ToneOpts) {
  const vol = getSettings().sfx
  if (vol <= 0) return
  const c = audio()
  if (!c || !bus) return

  const t = c.currentTime + delay
  const dur = ms / 1000
  const osc = c.createOscillator()
  const env = c.createGain()
  osc.type = type
  osc.frequency.setValueAtTime(freq, t)
  osc.frequency.exponentialRampToValueAtTime(Math.max(20, to ?? freq * 0.82), t + dur)

  env.gain.setValueAtTime(0.0001, t)
  env.gain.exponentialRampToValueAtTime(peak * vol, t + attack)
  env.gain.exponentialRampToValueAtTime(0.0001, t + dur)

  osc.connect(env); env.connect(bus)
  osc.start(t)
  osc.stop(t + dur + 0.02)
}

interface NoiseOpts {
  ms: number
  peak: number
  /** Cutoff at the start and at the end. The sweep is the sound: bright
   *  falling to dull is an impact; the reverse is something catching light. */
  from: number
  to: number
  filter?: BiquadFilterType
  /** Resonance. High values ring, which is what makes a parry metallic. */
  q?: number
  delay?: number
  attack?: number
}

function noise({ ms, peak, from, to, filter = 'bandpass', q = 1, delay = 0, attack = 0.004 }: NoiseOpts) {
  const vol = getSettings().sfx
  if (vol <= 0) return
  const c = audio()
  if (!c || !bus) return

  const t = c.currentTime + delay
  const dur = ms / 1000
  const src = c.createBufferSource()
  src.buffer = noiseBuffer(c)
  src.loop = true
  const bq = c.createBiquadFilter()
  bq.type = filter
  bq.Q.setValueAtTime(q, t)
  bq.frequency.setValueAtTime(from, t)
  bq.frequency.exponentialRampToValueAtTime(Math.max(40, to), t + dur)
  const env = c.createGain()
  env.gain.setValueAtTime(0.0001, t)
  env.gain.exponentialRampToValueAtTime(peak * vol, t + attack)
  env.gain.exponentialRampToValueAtTime(0.0001, t + dur)

  src.connect(bq); bq.connect(env); env.connect(bus)
  src.start(t)
  src.stop(t + dur + 0.02)
}

/** Picking a unit up. Small and upward: something is now in your hand. */
export function playSelect() {
  tone({ freq: vary(720, 0.05), to: vary(1080, 0.05), ms: 70, peak: 0.07, type: 'triangle' })
}

/** Putting one down during deployment. Firmer than a select, and final. */
export function playPlace() {
  tone({ freq: vary(300, 0.08), to: 150, ms: 110, peak: 0.15, type: 'triangle' })
  noise({ ms: 60, peak: 0.10, from: 2600, to: 700, q: 0.8 })
}

/** The board being laid at the start of a match: one little thud per tile,
 *  fired in the order the sweep runs (`delay` is seconds from now). Soft and
 *  short enough that 48 of them read as a rolling patter, not a wall; the
 *  compressor on the bus keeps the sum from piling up. */
export function playTileLay(step: number, delay: number) {
  // A mini thud: a short low body that drops fast, plus a tiny dull tick of
  // contact. A hair of pitch drift per tile so the sweep doesn't machine-gun.
  const f = vary(150 - (step % 4) * 6, 0.05)
  tone({ freq: f, to: f * 0.5, ms: 85, peak: 0.05, type: 'sine', delay, attack: 0.003 })
  noise({ ms: 30, peak: 0.012, from: 700, to: 300, filter: 'lowpass', delay, attack: 0.002 })
}

/** A unit crossing tiles: a brush of movement, then a soft landing under it. */
export function playMove() {
  noise({ ms: vary(170, 0.12), peak: 0.07, from: 900, to: 260, filter: 'lowpass', q: 0.7, attack: 0.05 })
  tone({ freq: vary(190, 0.1), to: 90, ms: 110, peak: 0.10, delay: 0.1 })
}

/**
 * A blow landing. `power` is the damage as a fraction of a heavy hit, and it
 * moves weight rather than volume alone: a scratch is short and bright, a real
 * hit is longer with more body under it.
 */
export function playHit(power = 0.5, delay = 0) {
  const p = Math.max(0.15, Math.min(1, power))
  noise({ ms: vary(90 + p * 70, 0.12), peak: 0.16 + p * 0.10, from: vary(1500, 0.15), to: 220, q: 1.1, delay })
  tone({ freq: vary(150, 0.1), to: 55, ms: 130 + p * 90, peak: 0.13 + p * 0.10, delay })
}

/** The answering blow: the same shape pitched up, so you hear that it came
 *  back at you rather than out from you. */
export function playCounter(power = 0.5, delay = 0) {
  const p = Math.max(0.15, Math.min(1, power))
  noise({ ms: vary(90, 0.12), peak: 0.14 + p * 0.08, from: vary(2400, 0.12), to: 600, q: 1.4, delay })
  tone({ freq: vary(230, 0.1), to: 90, ms: 120, peak: 0.10 + p * 0.06, type: 'triangle', delay })
}

/** A parry -- the answer that arrives before the blow it answers. Metallic and
 *  ringing, so it is never mistaken for an ordinary counter. */
export function playParry(power = 0.5, delay = 0) {
  const p = Math.max(0.15, Math.min(1, power))
  noise({ ms: 220, peak: 0.11 + p * 0.05, from: 3200, to: 2000, q: 9, delay })
  tone({ freq: vary(1560, 0.03), to: 1480, ms: 260, peak: 0.09, type: 'square', delay })
  tone({ freq: vary(2340, 0.03), to: 2200, ms: 180, peak: 0.05, type: 'square', delay: delay + 0.01 })
}

/** Mending. Two notes up a fifth with a soft attack -- the only sound in the
 *  set that swells instead of striking. */
export function playMend(delay = 0) {
  tone({ freq: 660, to: 660, ms: 180, peak: 0.09, delay, attack: 0.05 })
  tone({ freq: 990, to: 990, ms: 300, peak: 0.08, delay: delay + 0.09, attack: 0.06 })
}

/** Fire catching, or fire eating. A crackle that opens up rather than decays. */
export function playBurn(delay = 0) {
  noise({ ms: 420, peak: 0.11, from: 900, to: 2600, filter: 'highpass', q: 0.6, delay, attack: 0.08 })
  tone({ freq: vary(420, 0.2), to: 180, ms: 260, peak: 0.06, type: 'sawtooth', delay })
}

/** An axe into a trunk. Dry, woody, no ring at all. */
export function playChop(delay = 0) {
  tone({ freq: vary(210, 0.1), to: 70, ms: 110, peak: 0.18, type: 'triangle', delay })
  noise({ ms: 70, peak: 0.13, from: vary(1900, 0.15), to: 500, q: 2, delay })
}

/** A unit falling. The one sound in the game allowed to be slow. */
export function playDown(delay = 0) {
  tone({ freq: vary(260, 0.06), to: 60, ms: 420, peak: 0.15, type: 'sawtooth', delay, attack: 0.02 })
  noise({ ms: 300, peak: 0.08, from: 700, to: 120, filter: 'lowpass', q: 0.8, delay: delay + 0.04 })
}

/** Your turn. Two notes, up -- an invitation, not an alarm. */
export function playTurn() {
  tone({ freq: 587, to: 587, ms: 130, peak: 0.09, type: 'triangle', attack: 0.01 })
  tone({ freq: 784, to: 784, ms: 220, peak: 0.09, type: 'triangle', delay: 0.1, attack: 0.01 })
}

/** Won. A major arpeggio with the top note held. */
export function playWin() {
  ;[523, 659, 784, 1046].forEach((f, i) =>
    tone({ freq: f, to: f, ms: i === 3 ? 620 : 200, peak: 0.11, type: 'triangle', delay: i * 0.11, attack: 0.012 }),
  )
}

/** Lost. The same idea walked downhill. */
export function playLose() {
  ;[523, 415, 311].forEach((f, i) =>
    tone({ freq: f, to: f, ms: i === 2 ? 700 : 240, peak: 0.10, type: 'triangle', delay: i * 0.15, attack: 0.02 }),
  )
}
