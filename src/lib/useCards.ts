import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { Card } from './types'

/**
 * The roster, fetched once for the whole app.
 *
 * Two screens want it and they want it for different reasons. My Kingdom shows
 * the cards themselves. A match needs it only for the ABILITY TEXT: a unit in
 * `matches.state` carries the English ability it was deployed with, because
 * units are snapshotted at deploy and that is correct for stats -- a card
 * retuned mid-match must not change the match. Text is the exception. Nobody
 * is disadvantaged by a clearer sentence, the whole point of keeping ability
 * text in the database is that it can be fixed without a deploy, and the
 * snapshot cannot hold a translation that was written after the match started.
 *
 * So the text is looked up live, by slug, and the snapshot keeps the numbers.
 *
 * Cached at module level rather than per component: it is eleven rows that
 * change when Jared edits a card, and four screens mounting it in a session
 * should be one request.
 */
let cache: Card[] | null = null
let inflight: Promise<Card[]> | null = null
const listeners = new Set<(c: Card[]) => void>()

export function fetchCards(): Promise<Card[]> {
  if (cache) return Promise.resolve(cache)
  // Supabase's builder is a thenable rather than a real Promise, so it is
  // wrapped rather than stored directly -- otherwise `inflight` has no catch
  // and no finally, and the next caller gets a shape it cannot chain on.
  if (!inflight) {
    inflight = (async () => {
      const { data, error } = await supabase
        .from('cards').select('*').eq('is_active', true).order('sort')
      inflight = null
      if (error || !data) {
        // An empty roster is a card list with no ability text in it, which is
        // a screen missing a sentence -- not a screen that fails.
        console.warn('cards:', error?.message)
        return []
      }
      cache = data as Card[]
      listeners.forEach((l) => l(cache!))
      return cache
    })()
  }
  return inflight
}

/**
 * Forget the roster, so the next screen that wants it fetches it again.
 *
 * Exactly one caller: the admin editor, after a card is written. Everything
 * else reads from one cached fetch per session, which is right for eleven rows
 * nobody changes -- except at the moment somebody does, and then a screen still
 * showing the old numbers is a screen disagreeing with the database.
 */
export function clearCards() {
  cache = null
  inflight = null
  listeners.forEach((l) => l([]))
}

/**
 * Refetch and swap the cache in place, without the empty-array beat
 * clearCards() puts every listener through on its way to the next fetch.
 * clearCards() is right for the admin editor, which wants every OTHER screen
 * to know its old numbers are stale right away; it is wrong for a live
 * update arriving from Realtime, where the honest picture is "an edit
 * landed" and a menu tile or a hover card blanking for a frame is not that,
 * it is a flicker with no cause a player could name.
 */
async function refreshCards() {
  const { data, error } = await supabase
    .from('cards').select('*').eq('is_active', true).order('sort')
  if (error || !data) {
    console.warn('cards:', error?.message)
    return
  }
  cache = data as Card[]
  listeners.forEach((l) => l(cache!))
}

/**
 * One subscription for the whole app, opened the first time anything asks
 * for the roster and never torn down -- the roster is read for the entire
 * session, so there is no moment "nobody needs live updates anymore" for a
 * per-component effect to detect.
 *
 * 0040 added `cards` to the Realtime publication; this is the other half of
 * that migration's own promise, that a card edited in Admin Mode reaches an
 * open lobby or an open match without anybody refreshing the page.
 */
let realtimeStarted = false
function ensureRealtime() {
  if (realtimeStarted) return
  realtimeStarted = true
  supabase
    .channel('cards:live')
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'cards' },
      () => { void refreshCards() },
    )
    .subscribe()
}

export function useCards(): Card[] {
  const [cards, setCards] = useState<Card[]>(cache ?? [])
  useEffect(() => {
    let alive = true
    ensureRealtime()
    void fetchCards().then((c) => { if (alive) setCards(c) })
    const l = (c: Card[]) => { if (alive) setCards(c) }
    listeners.add(l)
    return () => { alive = false; listeners.delete(l) }
  }, [])
  return cards
}

/** Slug to card, for the lookup a match does on every hover. */
export function useCardsBySlug(): Map<string, Card> {
  const cards = useCards()
  return new Map(cards.map((c) => [c.slug, c]))
}
