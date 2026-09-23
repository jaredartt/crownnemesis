/**
 * The comics, live from comic_chapters/comic_pages instead of a static
 * public/comics/index.json -- see 0080_comics.sql. Same cache/listener
 * shape as useMusic.ts's tracks: a module-level cache shared by every
 * caller, refreshed on a realtime change to either table rather than
 * re-fetched per mount.
 *
 * Comics.tsx (the reader) and AdminComics.tsx (the editor) both want a
 * chapter WITH its pages attached, in reading order -- so this fetches the
 * embed (`*, comic_pages(*)`) in one round trip rather than two flat lists
 * the callers would have to zip together themselves. The embed's own row
 * order isn't asked to carry the page order (that's one more thing to get
 * right across postgrest versions) -- each chapter's pages are just sorted
 * by `sort` client-side once they arrive.
 *
 * A read error (offline, RLS misconfigured) is logged and treated the same
 * as "no chapters yet" -- same call useCards.ts/useStructures.ts already
 * make for their own tables, and Comics.tsx already had its own distinct
 * "nothing here yet" empty state to fall into.
 */
import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { ComicChapterWithPages, ComicPage } from './types'

let cache: ComicChapterWithPages[] | null = null
let inflight: Promise<ComicChapterWithPages[]> | null = null
const listeners = new Set<(c: ComicChapterWithPages[]) => void>()

async function fetchNow(): Promise<ComicChapterWithPages[]> {
  const { data, error } = await supabase
    .from('comic_chapters')
    .select('*, comic_pages(*)')
    .order('sort')
  if (error || !data) {
    console.warn('comic_chapters:', error?.message)
    return []
  }
  return (data as (ComicChapterWithPages & { comic_pages: ComicPage[] })[]).map((c) => ({
    ...c,
    pages: (c.comic_pages ?? []).slice().sort((a, b) => a.sort - b.sort),
  }))
}

function fetchChapters(): Promise<ComicChapterWithPages[]> {
  if (cache) return Promise.resolve(cache)
  if (!inflight) {
    inflight = fetchNow().then((rows) => {
      inflight = null
      cache = rows
      listeners.forEach((l) => l(rows))
      return rows
    })
  }
  return inflight
}

async function refresh() {
  const rows = await fetchNow()
  cache = rows
  listeners.forEach((l) => l(rows))
}

let realtimeStarted = false
function ensureRealtime() {
  if (realtimeStarted) return
  realtimeStarted = true
  supabase
    .channel('comics:live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'comic_chapters' },
        () => { void refresh() })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'comic_pages' },
        () => { void refresh() })
    .subscribe()
}

export function useComicChapters(): ComicChapterWithPages[] {
  const [chapters, setChapters] = useState<ComicChapterWithPages[]>(cache ?? [])
  useEffect(() => {
    let alive = true
    ensureRealtime()
    void fetchChapters().then((c) => { if (alive) setChapters(c) })
    const l = (c: ComicChapterWithPages[]) => { if (alive) setChapters(c) }
    listeners.add(l)
    return () => { alive = false; listeners.delete(l) }
  }, [])
  return chapters
}

/** True once the first fetch has settled (even if it came back empty) --
 *  Comics.tsx uses this to tell "still loading" from "no chapters yet". */
export function useComicChaptersLoaded(): boolean {
  const [loaded, setLoaded] = useState(cache !== null)
  useEffect(() => {
    let alive = true
    void fetchChapters().then(() => { if (alive) setLoaded(true) })
    return () => { alive = false }
  }, [])
  return loaded
}

/** Forces a re-fetch right now, bypassing the cache -- AdminComics.tsx
 *  calls this after a write that realtime may take a moment to echo back,
 *  so the editor reflects its own change immediately. */
export function refreshComics() {
  void refresh()
}
