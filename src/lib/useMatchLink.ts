import { useEffect, useState } from 'react'
import { matchLink } from './api'

/** A player whose heartbeat (every 10s) is older than this is treated as
 *  having a connection problem. One missed beat plus slack, so ordinary
 *  jitter never flashes the notice. */
const STALE_AFTER_S = 15
const POLL_MS = 3000

export interface MatchLink {
  /** That seat's player looks disconnected: they said goodbye (reload / close)
   *  or their heartbeat has gone quiet. Says nothing about WHY. */
  host: boolean
  guest: boolean
  /** THIS browser can't reach the server right now. */
  offline: boolean
}

/**
 * "Reconnecting with opponent..." (Jared: the other player needs to know when
 * someone is having connection issues, closing the tab, reloading -- not what
 * exactly happened, just that something is going on).
 *
 * Polls match_link() while a human-vs-human match is live. It never decides
 * anything on its own: the actual forfeit is the server's (sweep_matches,
 * after abandon_grace()); this is only the notice that a clock may be
 * running.
 */
export function useMatchLink(matchId: string | null, live: boolean): MatchLink {
  const [link, setLink] = useState<MatchLink>({ host: false, guest: false, offline: false })

  useEffect(() => {
    if (!matchId || !live) {
      setLink((l) => (l.host || l.guest || l.offline ? { host: false, guest: false, offline: false } : l))
      return
    }
    let alive = true
    let failures = 0
    const tick = async () => {
      const rows = await matchLink(matchId)
      if (!alive) return
      if (rows === null) {
        failures += 1
        // Two misses in a row (or the browser saying so) = we are the one
        // with the problem.
        if (failures >= 2 || !navigator.onLine) setLink((l) => (l.offline ? l : { ...l, offline: true }))
        return
      }
      failures = 0
      const gone = (side: 'host' | 'guest') => {
        const r = rows.find((x) => x.side === side)
        return Boolean(r && (r.away || r.age > STALE_AFTER_S))
      }
      const next = { host: gone('host'), guest: gone('guest'), offline: !navigator.onLine }
      setLink((l) => (l.host === next.host && l.guest === next.guest && l.offline === next.offline ? l : next))
    }
    void tick()
    const id = setInterval(tick, POLL_MS)
    const off = () => setLink((l) => (l.offline ? l : { ...l, offline: true }))
    const on = () => { void tick() }
    window.addEventListener('offline', off)
    window.addEventListener('online', on)
    return () => {
      alive = false
      clearInterval(id)
      window.removeEventListener('offline', off)
      window.removeEventListener('online', on)
    }
  }, [matchId, live])

  return link
}
