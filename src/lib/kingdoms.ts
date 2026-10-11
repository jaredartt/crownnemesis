import { DECK_SIZE, type Card, type Kingdom } from './types'

/**
 * The client half of 0024, and a mirror of it.
 *
 * Every rule here has a twin in the migration -- cn_kingdom_cap, the name
 * length, cn_clean_kingdoms' deck rules, deck_of's fieldable test,
 * cn_pick_kingdom. The server is still the authority: none of this is a
 * permission check and nothing here can let anything through. It exists so the
 * page can say what the server is going to say BEFORE the round trip, which is
 * the difference between "this kingdom is one card short" written under the
 * grid and a match that quietly starts with somebody else's army.
 *
 * CHANGE ONE, CHANGE BOTH.
 */

export const KINGDOM_CAP = 10
export const KINGDOM_NAME_MAX = 24

/**
 * Ids are made here rather than by the database, because a kingdom has to have
 * one before it has anything else: the page holds an unsaved one open while
 * you decide whether it is going to be a kingdom at all, and it needs a handle
 * for that. Time plus a little noise -- the server caps ids at 40 characters
 * and only ever compares them, so there is nothing to be clever about.
 */
export function newKingdomId(): string {
  return `k${Date.now().toString(36)}${Math.floor(Math.random() * 1296).toString(36)}`
}

/** cn_pick_kingdom: a selection that points at nothing lands on the first. */
export function pickKingdom(list: Kingdom[], id: string | null | undefined): Kingdom | null {
  return list.find((k) => k.id === id) ?? list[0] ?? null
}

/**
 * deck_of(), exactly: DECK_SIZE cards (five units and one crown), all of them
 * still in the roster, and exactly one crown. Anything else is not an army and
 * the server fields the default kingdom instead.
 */
export function fieldable(deck: string[], cards: Map<string, Card>): boolean {
  if (deck.length !== DECK_SIZE) return false
  let crowns = 0
  for (const slug of deck) {
    const c = cards.get(slug)
    if (!c) return false
    if (c.royal) crowns++
  }
  return crowns === 1
}

/**
 * Why it cannot be fielded -- or null when it can.
 *
 * ONE reason, not a list. Somebody two cards short and missing a crown is told
 * to pick two more cards; the crown becomes the thing to say once it is the
 * only thing left to say.
 */
export type Unready = 'tooFew' | 'noCrown' | 'twoCrowns' | 'hasRetired'

export function notFieldable(deck: string[], cards: Map<string, Card>): Unready | null {
  if (deck.some((s) => !cards.has(s))) return 'hasRetired'
  if (deck.length < DECK_SIZE) return 'tooFew'
  const crowns = deck.filter((s) => cards.get(s)?.royal).length
  if (crowns === 0) return 'noCrown'
  if (crowns > 1) return 'twoCrowns'
  return null
}

/**
 * And the sentence for it, in whatever language is in force.
 *
 * Written out as four literal t() calls on purpose. A key BUILT from a value
 * -- `t('kingdom.' + why)` -- is invisible to the check that every key the
 * code asks for actually exists, and this project has already shipped one of
 * those: a theme button whose key was assembled from the setting's value
 * rendered `settings.themeSystem` on screen, and no dictionary-against-
 * dictionary comparison could ever have seen it.
 *
 * The translator is passed in rather than reached for, because this file is
 * not a component and useT is a hook. Same arrangement as cine.ts.
 */
export function unreadyText(
  why: Unready, deck: string[], t: (k: string, v?: Record<string, unknown>) => string,
): string {
  switch (why) {
    case 'tooFew':     return t('kingdom.tooFew', { n: DECK_SIZE - deck.length })
    case 'noCrown':    return t('kingdom.noCrown')
    case 'twoCrowns':  return t('kingdom.twoCrowns')
    case 'hasRetired': return t('kingdom.hasRetired')
  }
}

/**
 * The token on a kingdom's chip. An explicit choice wins; otherwise the first
 * card in, which is what the 0024 backfill gave everybody's first kingdom and
 * is a better guess than nothing.
 */
export function kingdomIcon(k: Kingdom): string | null {
  if (k.icon && k.deck.includes(k.icon)) return k.icon
  return k.icon ?? k.deck[0] ?? null
}

/** cn_clean_kingdoms' deck rules: no repeats, nothing retired, never long. */
export function cleanDeck(deck: string[], cards: Map<string, Card>): string[] {
  const out: string[] = []
  for (const s of deck) {
    if (out.length >= DECK_SIZE) break
    if (out.includes(s) || !cards.has(s)) continue
    out.push(s)
  }
  return out
}

/**
 * A blank kingdom is not a kingdom yet, and is the one thing never sent.
 *
 * Tapping "new" and then wandering off has to leave nothing behind. The page
 * needs the thing to exist locally the moment you tap -- it is what you are
 * looking at -- but a row on the server for an empty box you glanced at and
 * left is somebody's cap spent on nothing.
 */
export function isBlank(k: Kingdom): boolean {
  return !k.name && !k.icon && k.deck.length === 0
}
