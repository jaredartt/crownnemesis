/**
 * Friends, pending requests, and who's online -- live from the database. Same
 * cache/listener/Realtime shape as useMenuSections.ts, folded over three
 * tables instead of one because a friends screen needs all three read
 * together far more often than it needs any one of them alone.
 *
 * Scoped to whichever account is signed in this tab rather than truly global
 * -- see clearFriends(), called from useAuth.ts's sign-out path -- but kept
 * as module state like the rest of this file's siblings because exactly one
 * account is ever signed in per tab, the same assumption settings.ts and
 * i18n.ts already make.
 */
import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { FriendRequestRow, FriendRow, UserPresenceRow } from './types'

export interface FriendsState {
  friends: FriendRow[]
  /** Pending requests somebody else sent you. */
  incoming: FriendRequestRow[]
  /** Pending requests you sent somebody else. */
  outgoing: FriendRequestRow[]
  /** user_id -> seen_at, for yourself and your friends only -- see the RLS
   *  policy on user_presence for why nobody wider shows up here. */
  presence: Record<string, string>
}

const EMPTY: FriendsState = { friends: [], incoming: [], outgoing: [], presence: {} }

/** A row is "online" if it was touched in the last 30s. touch_presence() is
 *  called roughly every 20s (see App.tsx), so this gives a tab that just
 *  closed a beat of slack before its dot goes grey rather than flickering it
 *  the instant a heartbeat is merely late. */
export const PRESENCE_WINDOW_MS = 30_000
export function isOnline(seenAt: string | undefined): boolean {
  if (!seenAt) return false
  return Date.now() - new Date(seenAt).getTime() < PRESENCE_WINDOW_MS
}

let cache: FriendsState = EMPTY
let uidCached: string | null = null
let inflight: Promise<void> | null = null
const listeners = new Set<(s: FriendsState) => void>()

async function fetchNow(uid: string): Promise<FriendsState> {
  const [friendsRes, reqRes, presRes] = await Promise.all([
    supabase.from('friends').select('*'),
    supabase.from('friend_requests').select('*').eq('status', 'pending'),
    supabase.from('user_presence').select('*'),
  ])
  const reqs = (reqRes.data ?? []) as FriendRequestRow[]
  const presence: Record<string, string> = {}
  for (const p of (presRes.data ?? []) as UserPresenceRow[]) presence[p.user_id] = p.seen_at
  return {
    friends: (friendsRes.data ?? []) as FriendRow[],
    incoming: reqs.filter((r) => r.to_id === uid),
    outgoing: reqs.filter((r) => r.from_id === uid),
    presence,
  }
}

async function refresh(uid: string) {
  const s = await fetchNow(uid)
  cache = s
  listeners.forEach((l) => l(s))
}

/** Called after a local write (send/respond/remove) so the acting tab's own
 *  screen updates without waiting on the websocket round trip. Needed for
 *  real correctness here, not just snappiness: declining a request touches
 *  ONLY friend_requests, which is deliberately off the realtime publication
 *  (see 0043's own comment on that), so nothing would otherwise tell this
 *  tab the request it just answered is gone. */
export async function refreshFriends(uid: string) {
  await refresh(uid)
}

/** Forgets the cache outright -- used on sign-out, the same reason
 *  clearMenuSections() exists for its own table. */
export function clearFriends() {
  cache = EMPTY
  uidCached = null
  inflight = null
}

let realtimeStarted = false
function ensureRealtime(uid: string) {
  if (realtimeStarted) return
  realtimeStarted = true
  supabase
    .channel('friends:live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'friends' },
        () => { void refresh(uid) })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'friend_requests' },
        () => { void refresh(uid) })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'user_presence' },
        () => { void refresh(uid) })
    .subscribe()
}

export function useFriends(uid: string | null): FriendsState {
  const [state, setState] = useState<FriendsState>(cache)
  useEffect(() => {
    if (!uid) return
    let alive = true
    if (uidCached !== uid) { cache = EMPTY; uidCached = uid; inflight = null }
    ensureRealtime(uid)
    if (!inflight) {
      inflight = refresh(uid).then(() => { inflight = null })
    }
    inflight.then(() => { if (alive) setState(cache) })
    const l = (s: FriendsState) => { if (alive) setState(s) }
    listeners.add(l)
    return () => { alive = false; listeners.delete(l) }
  }, [uid])
  return state
}
