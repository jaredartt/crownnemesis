import type { Fx, Obstacle, Swing, Unit } from './types'

/**
 * The exchange, turned into something that can be watched.
 *
 * cn_attack decides a fight and records it swing by swing (0020); this turns
 * that record into a timeline of beats with a clock, a running health total
 * and a sentence for each one. It decides nothing -- every number here was
 * decided by Postgres and is being read back, which is the same relationship
 * rules.ts has to the board.
 *
 * All of it is pure. No React, no DOM, no clock of its own: a timeline is a
 * value, and a value can be checked in node against four hundred random
 * fights, which is exactly what it is.
 *
 * The translator is INJECTED rather than imported, and that is what keeps the
 * above true: importing i18n would drag the settings store, the dictionaries
 * and a dynamic import into a module whose whole value is that it can be run
 * with nothing around it. A caller has a `t` already; handing it over costs
 * one argument.
 */
export type Tr = (key: string, vars?: Record<string, unknown>) => string

/** What a caller with nothing to say uses. Renders the key, which is what
 *  i18n does for a missing string too -- visibly wrong beats invisibly so. */
export const rawTr: Tr = (k, v) =>
  v ? `${k} ${JSON.stringify(v)}` : k

/* ---------------------------------------------------------------------------
 * How long each beat is on screen.
 *
 * THESE NUMBERS ARE MIRRORED IN cn_cine_ms() IN 0021_cinematic_clock.sql, and
 * the server buys the player exactly this much extra clock. If the picture
 * here runs longer than the budget there, the player loses their turn watching
 * it -- so if you change one, change both, and 12_clock.sql pins the same
 * table from the other side.
 * ------------------------------------------------------------------------- */
export const BEAT_MS: Record<Swing['k'], number> = {
  hit: 700,
  heal: 700,
  // Shorter than a blow because there is no health bar to drain -- a parry is
  // a flash and a ring, and holding it longer only delays the answer.
  parry: 600,
  burn: 450,
  // The longest single beat. A unit leaving the board should be allowed to.
  down: 800,
}
/** The two of them squaring up, before anything is swung. */
export const LEAD_MS = 900
/** And a moment at the end to read the last number before the board returns. */
export const HOLD_MS = 700
/** Nothing today can exceed this. Abilities are coming; an ability that swings
 *  fifty times must not hand its owner a minute of thinking time. */
export const CINE_CAP_MS = 12000

/** The freeze on contact. Short, and the whole reason a blow lands rather than
 *  merely arriving -- it is the single cheapest thing that makes a hit feel
 *  like one. Inside a beat, not added to it, so it costs no clock. */
export const HITSTOP_MS = 90

/** Mirrors cn_cine_ms(). */
export function cineMs(swings: Swing[]): number {
  const body = swings.reduce((n, s) => n + (BEAT_MS[s.k] ?? 0), 0)
  return Math.min(CINE_CAP_MS, LEAD_MS + HOLD_MS + body)
}

/**
 * The swings, or the best that can be said without them.
 *
 * A match that was already running when 0020 landed has an fx with no list in
 * it, and the cinematic still has to play something honest. The aggregates
 * cannot be un-added -- that is the whole reason 0020 exists -- so the fallback
 * does not pretend: one blow, one answer, the burns and the fallings, in the
 * order they must have happened. No parries, because `parries: 2` cannot say
 * which swings they caught, and inventing them would narrate a fight nobody
 * fought.
 */
export function swingsOf(fx: Fx): Swing[] {
  if (Array.isArray(fx.swings)) return fx.swings
  // Only an ability has no target, and an ability always carries its swings --
  // so there is nothing here to reconstruct from the totals.
  if (fx.tgt == null) return []
  const tgt = fx.tgt
  const out: Swing[] = []
  if (fx.heal > 0) {
    out.push({ k: 'heal', by: fx.atk, at: tgt, dmg: fx.heal, why: 'mend' })
    return out
  }
  if (fx.dmg > 0 || fx.counter === 0) {
    out.push({
      k: 'hit', by: fx.atk, at: tgt, dmg: fx.dmg,
      crit: fx.crit ?? false, counter: false, why: fx.tree ? 'tree' : 'strike',
    })
  }
  if (fx.burnAtk > 0) out.push({ k: 'burn', by: fx.atk, at: fx.atk, dmg: fx.burnAtk })
  if (fx.killedTgt) out.push({ k: 'down', by: tgt, at: tgt })
  if (fx.counter > 0) {
    out.push({
      k: 'hit', by: tgt, at: fx.atk, dmg: fx.counter,
      crit: fx.critCounter ?? false, counter: true,
      why: fx.parry ? 'quick' : 'counter', first: fx.parry,
    })
  }
  if (fx.burnTgt > 0) out.push({ k: 'burn', by: tgt, at: tgt, dmg: fx.burnTgt })
  if (fx.killedAtk) out.push({ k: 'down', by: fx.atk, at: fx.atk })
  return out
}

/** Either end of the duel. A tree gets one too -- it has hit points and it can
 *  fall, which is all this screen needs of anybody. */
export interface Fighter {
  id: string
  name: string
  art: string | null
  accent: string
  hp: number
  maxHp: number
  side: 'host' | 'guest' | null
  /** Since 0040. Null for a tree -- there is no card to look a sound up on.
   *  Duel.tsx uses it to find this fighter's uploaded attack/ability/passive
   *  sound, if it has one; nothing else here reads it. */
  slug: string | null
}

export interface Beat {
  swing: Swing
  /** Milliseconds from the opening of the cinematic. */
  at: number
  ms: number
  /** Which panel acts. The other one is the one it happens to. */
  actor: 'a' | 'b'
  /** Health AFTER this beat, for both, so a bar can be driven straight from
   *  the beat rather than by replaying everything before it. */
  aHp: number
  bHp: number
  /** The sentence, and the rule behind it. `note` is empty when there is no
   *  rule worth naming -- most blows are just blows. */
  text: string
  note: string
  /** The number that flies off the receiving panel, and where it lands. */
  pop: number
  popAt: 'a' | 'b' | null
  popKind: 'dmg' | 'heal' | 'burn'
  shake: boolean
}

export interface Cine {
  /** The exchange's own number, straight off fx.seq. It is what makes one
   *  cinematic distinguishable from the next -- two identical trades in a row
   *  are identical in every other field, and something has to tell them
   *  apart when they are queued. */
  seq: number
  beats: Beat[]
  ms: number
  /** The two panels, as they stood BEFORE the exchange. */
  a: Fighter
  b: Fighter
}

export function fighterOf(u: Unit): Fighter {
  return {
    id: u.id, name: u.name, art: u.art, accent: u.accent,
    hp: u.hp, maxHp: u.maxHp, side: u.owner, slug: u.slug,
  }
}
/**
 * `info` is the actual structure's name/art/accent, resolved by the caller
 * from the structures catalog (Board.tsx, via useStructuresBySlug) -- this
 * file stays pure and does no fetching of its own (see this file's header
 * on why: no React, no DOM, no i18n). Before this, every obstacle drew as
 * a hardcoded 'Tree'/no-art/forest-green regardless of what actually stood
 * there, which is the whole reason a wall, a trap or a custom structure's
 * fight scene always looked and read like a tree. The default is kept as
 * the fallback for a caller that genuinely has nothing better (a harness,
 * or a fetch that failed) -- not silently different behaviour, the exact
 * picture this always drew.
 */
export function fighterOfTree(
  t: Obstacle,
  info?: { name: string; art: string | null; accent: string },
): Fighter {
  return {
    id: t.id,
    name: info?.name ?? 'Tree',
    art: info?.art ?? null,
    accent: info?.accent ?? '#6b8f4e',
    hp: t.hp, maxHp: t.maxHp, side: null, slug: null,
  }
}

const n = (v: number | undefined) => v ?? 0

/**
 * Build the timeline.
 *
 * `a` and `b` are the two fighters as they stood BEFORE the exchange -- the
 * caller has that snapshot and this function cannot recover it, because a unit
 * that died is already gone from the board by the time the fx arrives.
 *
 * Health is walked FORWARD from those two, never back-calculated from what
 * survived. Back-calculation would work for the living and silently invent a
 * number for the dead, and the dead are the ones the last beat is about.
 */
export function buildCine(fx: Fx, a: Fighter, b: Fighter, t: Tr = rawTr): Cine {
  const swings = swingsOf(fx)
  const beats: Beat[] = []
  let aHp = a.hp
  let bHp = b.hp
  let at = LEAD_MS

  for (const s of swings) {
    const actor: 'a' | 'b' = s.by === a.id ? 'a' : 'b'
    const ms = BEAT_MS[s.k] ?? 0
    let pop = 0
    let popAt: 'a' | 'b' | null = null
    let popKind: Beat['popKind'] = 'dmg'
    let text = ''
    let note = ''
    let shake = false

    const actorName = actor === 'a' ? a.name : b.name
    const otherName = actor === 'a' ? b.name : a.name

    if (s.k === 'hit') {
      const onA = s.at === a.id
      pop = n(s.dmg); popAt = onA ? 'a' : 'b'; popKind = 'dmg'
      if (onA) aHp = Math.max(0, aHp - n(s.dmg))
      else bHp = Math.max(0, bHp - n(s.dmg))
      shake = Boolean(s.crit)

      if (s.why === 'mist') {
        // The blow went where the Rogue had been. Named before every other
        // branch because a dodge is not a weaker version of a hit -- it is a
        // different thing that happens to arrive in a hit's clothing.
        text = t('duel.mist', { who: actorName, target: otherName })
        note = t('duel.noteMist')
      } else if (s.why === 'twice') {
        text = t('duel.twice', { who: actorName, n: n(s.dmg) })
        note = t('duel.noteTwice')
      } else if (s.why === 'poison') {
        text = t('duel.venom', { who: actorName, target: otherName, n: n(s.dmg) })
        note = t('duel.noteVenom')
      } else if (s.why === 'fire') {
        text = t('duel.fire', { who: actorName, n: n(s.dmg) })
        note = t('duel.noteFire')
      } else if (s.why === 'ability') {
        text = t('duel.ability', { who: actorName, target: otherName, n: n(s.dmg) })
      } else if (s.why === 'tree') {
        text = t('duel.strikesTree', { who: actorName, n: n(s.dmg) })
      } else if (s.why === 'quick') {
        text = t('duel.answersFirst', { who: actorName, n: n(s.dmg) })
        note = t('duel.noteQuick')
      } else if (s.counter) {
        text = t('duel.answers', { who: actorName, n: n(s.dmg) })
        note = t('duel.noteCounterOnly')
      } else {
        text = t('duel.strikes', { who: actorName, target: otherName, n: n(s.dmg) })
      }
      // Reductions, in the order cn_damage applies them, and only the ones
      // that actually fired. A caption listing rules that did not apply is
      // noise dressed as detail.
      const why: string[] = []
      if (s.crit) why.push(t('duel.noteCrit'))
      if (s.counter && s.why !== 'quick') why.push(t('duel.noteCounter'))
      if (s.def) why.push(t('duel.noteGuard'))
      // A dodge has nothing to reduce: no crit, no counter, no guard applied
      // to a blow that never arrived, so its own note stands.
      if (why.length && s.why !== 'mist') note = why.join(', ') + '.'
      if (s.why === 'quick') {
        note = t('duel.noteQuick') + (s.crit ? t('duel.noteQuickCrit') : '')
      }
    } else if (s.k === 'heal') {
      const onA = s.at === a.id
      pop = n(s.dmg); popAt = onA ? 'a' : 'b'; popKind = 'heal'
      if (onA) aHp = Math.min(a.maxHp, aHp + n(s.dmg))
      else bHp = Math.min(b.maxHp, bHp + n(s.dmg))
      if (s.why === 'steal') {
        // Nyxara. The healing is on the SWINGER, not on anyone it mended --
        // `by` and `at` are the same unit -- so the mend caption, which names
        // two, would name the wrong second one.
        text = t('duel.steals', { who: actorName, n: n(s.dmg) })
        note = t('duel.noteSteal')
      } else {
        text = t('duel.mends', { who: actorName, target: otherName, n: n(s.dmg) })
        note = t('duel.noteMend')
      }
    } else if (s.k === 'parry') {
      text = t('duel.parries', { who: actorName })
      note = t(s.why === 'all' ? 'duel.noteParryAll' : 'duel.noteParryRoll')
      shake = true
    } else if (s.k === 'burn') {
      const onA = s.by === a.id
      pop = n(s.dmg); popAt = onA ? 'a' : 'b'; popKind = 'burn'
      if (onA) aHp = Math.max(0, aHp - n(s.dmg))
      else bHp = Math.max(0, bHp - n(s.dmg))
      text = t('duel.burns', { who: actorName, n: n(s.dmg) })
      note = t('duel.noteBurn')
    } else {
      // The server says this one fell, so the bar reads empty whatever the
      // arithmetic before it came to. In the ordinary case the blow already
      // took it to nothing -- but in the fallback, where only the totals
      // survived, the killing damage may have been riposte that the totals
      // cannot place. A full bar under the word "falls" is a lie either way.
      if (s.by === a.id) aHp = 0
      else bHp = 0
      text = t('duel.falls', { who: actorName })
      shake = true
    }

    beats.push({ swing: s, at, ms, actor, aHp, bHp, text, note, pop, popAt, popKind, shake })
    at += ms
  }

  return { seq: fx.seq, beats, ms: cineMs(swings), a, b }
}

/**
 * The same fight, told faster.
 *
 * Presentation only, and NOT mirrored by cn_cine_ms(). Every other duration in
 * this file has a twin in 0021 because the server pays for the time out of the
 * turn clock; this one does not, because the clock is unchanged whichever way
 * the setting is pointed -- see CineMode in settings.ts for why.
 *
 * It re-times rather than rebuilds: the beats, their captions and their
 * reductions are exactly the ones buildCine() produced, moved closer together.
 * The squaring-up at the front is what goes first, because it is the part that
 * carries no information -- and the gaps are scaled rather than replaced with
 * a constant, so a parry that was always shorter than a blow stays shorter.
 */
export const QUICK_LEAD = 200
export const QUICK_HOLD = 260
export const QUICK_RATE = 0.55

export function quicken(c: Cine): Cine {
  if (!c.beats.length) return { ...c, ms: QUICK_LEAD + QUICK_HOLD }
  const beats = c.beats.map((b) => ({ ...b }))
  let at = QUICK_LEAD
  for (let i = 0; i < c.beats.length; i++) {
    beats[i].at = Math.round(at)
    const nextAt = i + 1 < c.beats.length ? c.beats[i + 1].at : c.ms - HOLD_MS
    at += Math.max(90, (nextAt - c.beats[i].at) * QUICK_RATE)
  }
  return { ...c, beats, ms: Math.round(at + QUICK_HOLD) }
}
