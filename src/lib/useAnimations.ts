import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { Animation } from './types'

/**
 * The animations catalog, fetched once for the whole app -- same shape as
 * useStructures.ts, for the same reason (see that file's own comment):
 * a handful of rows that change only when an admin edits Animations, so
 * one request shared across however many components mount this in a
 * session is enough. No realtime subscription either, same tradeoff
 * useStructures.ts already made -- an animation's colour/shape changing
 * mid-match is a cosmetic edge case a page reload already covers, and this
 * table does not even affect a live match yet (0158 is catalog-only; see
 * that migration's header).
 */
let cache: Animation[] | null = null
let inflight: Promise<Animation[]> | null = null
const listeners = new Set<(a: Animation[]) => void>()

export function fetchAnimations(): Promise<Animation[]> {
  if (cache) return Promise.resolve(cache)
  if (!inflight) {
    inflight = (async () => {
      const { data, error } = await supabase
        .from('animations').select('*').eq('is_active', true).order('sort')
      inflight = null
      if (error || !data) {
        console.warn('animations:', error?.message)
        return []
      }
      cache = data as Animation[]
      listeners.forEach((l) => l(cache!))
      return cache
    })()
  }
  return inflight
}

export function useAnimations(): Animation[] {
  const [rows, setRows] = useState<Animation[]>(cache ?? [])
  useEffect(() => {
    let alive = true
    void fetchAnimations().then((a) => { if (alive) setRows(a) })
    const l = (a: Animation[]) => { if (alive) setRows(a) }
    listeners.add(l)
    return () => { alive = false; listeners.delete(l) }
  }, [])
  return rows
}

/** Slug to animation, for the lookup a live-playback renderer will do once
 *  that fast-follow lands (see 0158's header), and for AdminCards.tsx's own
 *  animationLabel in the sentence builder's dropdown. */
export function useAnimationsBySlug(): Map<string, Animation> {
  const rows = useAnimations()
  return new Map(rows.map((a) => [a.slug, a]))
}

