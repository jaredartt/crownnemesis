import type { Unit } from './types'

/**
 * What is ON a unit.
 *
 * Every read of an affliction goes through here, for the reason 0034's own
 * header gives: `effects->>'burn'` spelled slightly wrong is a rule that
 * silently stops applying, and that is exactly how the retired `burned` flag
 * came to be written in two places and read in four. One function per
 * affliction, and the legacy fallback lives in one of them rather than in
 * every caller.
 */

/** The fire. Permanent until death -- 0034 removed the cure. */
export function isBurning(u: Unit): boolean {
  // `burned` is the pre-0034 spelling. A match that was already in flight when
  // 0034 landed still carries it and never grew an `effects` object, so a unit
  // with neither is simply not burning.
  return u.effects?.burn === true || u.burned === true
}

/** The rot. Takes 10% of a maximum at the start of its own side's turn. */
export function isPoisoned(u: Unit): boolean {
  return u.effects?.poison === true
}

/** Goes still owed to the cyclone. Zero for everybody who is not stunned. */
export function stunLeft(u: Unit): number {
  return u.effects?.stun ?? 0
}

export function isStunned(u: Unit): boolean {
  return stunLeft(u) > 0
}

/** Every affliction on a unit, in the order the unit bar should draw them. */
export type Affliction = 'burn' | 'poison' | 'stun'

/**
 * Everything the mark row can draw. The guard is a choice the unit made and
 * the swamp is a fact about where it is STANDING rather than anything on it --
 * neither is an affliction, but all five share the row, so they share a type.
 */
export type Mark = Affliction | 'guard' | 'swamp'

export function afflictionsOf(u: Unit): Affliction[] {
  const out: Affliction[] = []
  if (isBurning(u)) out.push('burn')
  if (isPoisoned(u)) out.push('poison')
  if (isStunned(u)) out.push('stun')
  return out
}

/** The picture each one is drawn with, relative to the site's base URL --
 *  pass it through artUrl(), which is what puts the base on the front.
 *  Kept beside the reader so a new affliction cannot be added without one,
 *  and named for what it MEANS rather than what it looks like, so a redrawn
 *  icon is a replaced file and nothing else.
 *
 *  The guard is here too even though it is not an affliction: it shares the
 *  row, it has to share the set, or the four stop looking like one family. */
export const MARK_ART: Record<Mark, string> = {
  guard: 'fx/guard.webp',
  burn: 'fx/burn.webp',
  poison: 'fx/poison.webp',
  stun: 'fx/stun.webp',
  swamp: 'fx/swamp.webp',
}
