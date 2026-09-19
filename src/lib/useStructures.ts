import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { Structure } from './types'

/**
 * The structures catalog, fetched once for the whole app -- the same shape
 * as useCards.ts, for the same reason: a match needs a structure's own
 * name/art_url/accent to draw it honestly (the fight cinematic -- see
 * cine.ts's fighterOfTree), and that lives in the catalog, not on the
 * obstacle JSON the board already carries (which only ever has `kind`,
 * `hp`, `owner`, `by`).
 *
 * Cached at module level rather than per component: it is a handful of rows
 * that change only when an admin edits Structures, and however many boards
 * mount this in a session should still be one request.
 *
 * No realtime subscription, unlike useCards.ts -- a card's ability text can
 * change under a match already in progress and that has to reach an open
 * board without a refresh; a structure's name/art/accent changing mid-match
 * is a cosmetic edge case a page reload already covers, and the smaller
 * hook is honest about being a scoped stated cut rather than an oversight.
 */
let cache: Structure[] | null = null
let inflight: Promise<Structure[]> | null = null
const listeners = new Set<(s: Structure[]) => void>()

export function fetchStructures(): Promise<Structure[]> {
  if (cache) return Promise.resolve(cache)
  if (!inflight) {
    inflight = (async () => {
      const { data, error } = await supabase
        .from('structures').select('*').eq('is_active', true)
      inflight = null
      if (error || !data) {
        // A structures fetch that fails leaves fighterOfTree's own fallback
        // (the raw kind string) to carry the name -- not a screen that
        // fails, the same convention useCards.ts's own comment states.
        console.warn('structures:', error?.message)
        return []
      }
      cache = data as Structure[]
      listeners.forEach((l) => l(cache!))
      return cache
    })()
  }
  return inflight
}

export function useStructures(): Structure[] {
  const [rows, setRows] = useState<Structure[]>(cache ?? [])
  useEffect(() => {
    let alive = true
    void fetchStructures().then((s) => { if (alive) setRows(s) })
    const l = (s: Structure[]) => { if (alive) setRows(s) }
    listeners.add(l)
    return () => { alive = false; listeners.delete(l) }
  }, [])
  return rows
}

/** Slug to structure, for the lookup the Duel cinematic does on every fx
 *  that names an obstacle. */
export function useStructuresBySlug(): Map<string, Structure> {
  const rows = useStructures()
  return new Map(rows.map((s) => [s.slug, s]))
}
