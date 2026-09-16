/**
 * Which lobby tiles are shown, and in what order -- live from the database.
 * See 0042_menu_sections.sql. Same cache/listener/Realtime shape as
 * useCards.ts and useMusic.ts; Lobby.tsx folds this over its own TILES
 * constant rather than reading colours or pictures from here, because those
 * stay presentation and belong in the client.
 */
import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { MenuSection } from './types'

let cache: MenuSection[] | null = null
let inflight: Promise<MenuSection[]> | null = null
const listeners = new Set<(s: MenuSection[]) => void>()

async function fetchNow(): Promise<MenuSection[]> {
  const { data, error } = await supabase.from('menu_sections').select('*').order('sort')
  if (error || !data) {
    console.warn('menu_sections:', error?.message)
    return []
  }
  return data as MenuSection[]
}

function fetchSections(): Promise<MenuSection[]> {
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

async function refreshSections() {
  const rows = await fetchNow()
  cache = rows
  listeners.forEach((l) => l(rows))
}

/** Exactly the pattern AdminCards uses on `cards` after a save: forget the
 *  cache so the next read is fresh. Realtime (below) makes this unnecessary
 *  for every OTHER screen, but the Menu tab itself wants its own edit back
 *  immediately, not on the round trip through a websocket. */
export function clearMenuSections() {
  cache = null
  inflight = null
}

let realtimeStarted = false
function ensureRealtime() {
  if (realtimeStarted) return
  realtimeStarted = true
  supabase
    .channel('menu-sections:live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'menu_sections' },
        () => { void refreshSections() })
    .subscribe()
}

export function useMenuSections(): MenuSection[] {
  const [rows, setRows] = useState<MenuSection[]>(cache ?? [])
  useEffect(() => {
    let alive = true
    ensureRealtime()
    void fetchSections().then((r) => { if (alive) setRows(r) })
    const l = (r: MenuSection[]) => { if (alive) setRows(r) }
    listeners.add(l)
    return () => { alive = false; listeners.delete(l) }
  }, [])
  return rows
}
