import type { MatchState, Unit } from './types'
// rules.ts imports awake() back out of here, which is a cycle -- and a safe
// one: neither module TOUCHES the other's exports while it is being evaluated,
// only inside functions called later. Splitting the file the other way would
// mean a second copy of the Chebyshev distance, and two copies of a distance
// is how a board and a server stop agreeing about who can reach whom.
import { cheb } from './rules'

/**
 * Umiro's swamp: nearby units cannot use Passives or Abilities.
 *
 * The client's copy of cn_swamped() and cn_awake() from 0037_the_swamp.sql,
 * and the same shape for the same reason: rather than ask "is this unit
 * silenced" at each of the dozen places a passive is read, ask it ONCE and
 * hand the rest of the code a unit with its passives already gone. Every
 * caller then goes on reading the fields it always read.
 *
 * As always, this decides nothing. The Postgres function is asked again before
 * anything happens, and its answer is the one that counts. This exists so the
 * board can grey the Ability button BEFORE you press it.
 */

/** Is this unit standing next to somebody's swamp? Anybody's -- the marsh does
 *  not ask whose boots are in it. */
export function isSwamped(state: MatchState, u: Unit): boolean {
  return state.units.some(
    (q) => q.swamps === true && q.hp > 0 && cheb(q, u) === 1,
  )
  // No "and not itself": a unit is never one tile from itself. Two Umiros side
  // by side DO silence each other, and `swamps` is the one field awake() never
  // strips, so neither of them stops being a swamp.
}

/**
 * The unit as the rules should see it.
 *
 * Takes the ability, what it summons, the royal aura, and every flag or number
 * that implements a card's passive. Leaves flight and trampling (those are
 * what a CLASS is), the body, the reach, and the parry and crit dice -- Lium's
 * raised rates live in two numbers on his card rather than in a flag, so the
 * swamp takes his "parries all parries" and leaves his dice alone. See the
 * header of 0037_the_swamp.sql, which is where that list is decided.
 */
export function awake(state: MatchState, u: Unit): Unit {
  if (!isSwamped(state, u)) return u
  return {
    ...u,
    abilityKind: null,
    summonKind: null,
    auraKind: null,
    parryAll: false,
    parries: false,
    slippery: false,
    twicePct: 0,
    regenPct: 0,
    poisonsAdj: false,
    stuns: false,
    vsPoisoned: 0,
    lifestealPct: 0,
  }
}
