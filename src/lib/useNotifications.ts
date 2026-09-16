/**
 * The bell's own list -- live from the database. Same cache/listener/Realtime
 * shape as useMenuSections.ts; scoped per signed-in account the same way
 * useFriends.ts is, for the same reason.
 *
 * fetch_notifications() both lists and sweeps (see 0044's own comment on
 * why the sweep is lazy), so a plain refetch here is also the cleanup.
 */
import { useEffect, useState } from 'react'
import { fetchNotifications } from './api'
import { supabase } from './supabase'
import type { NotificationRow } from './types'

let cache: NotificationRow[] = []
let uidCached: string | null = null
let inflight: Promise<void> | null = null
const listeners = new Set<(rows: NotificationRow[]) => void>()

async function refresh() {
  const rows = await fetchNotifications()
  cache = rows
  listeners.forEach((l) => l(rows))
}

/** Called after marking one read/all read, so the bell's own badge updates
 *  before the round trip -- see clearMenuSections() for the pattern. */
export function clearNotifications() {
  cache = []
  uidCached = null
  inflight = null
}

let realtimeStarted = false
function ensureRealtime() {
  if (realtimeStarted) return
  realtimeStarted = true
  supabase
    .channel('notifications:live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'notifications' },
        () => { void refresh() })
    .subscribe()
}

export function useNotifications(uid: string | null): NotificationRow[] {
  const [rows, setRows] = useState<NotificationRow[]>(cache)
  useEffect(() => {
    if (!uid) return
    let alive = true
    if (uidCached !== uid) { cache = []; uidCached = uid; inflight = null }
    ensureRealtime()
    if (!inflight) {
      inflight = refresh().then(() => { inflight = null })
    }
    inflight.then(() => { if (alive) setRows(cache) })
    const l = (r: NotificationRow[]) => { if (alive) setRows(r) }
    listeners.add(l)
    return () => { alive = false; listeners.delete(l) }
  }, [uid])
  return rows
}
