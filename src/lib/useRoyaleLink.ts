import { useEffect, useState } from 'react'
import { royaleLink } from './api'

/** Same threshold as useMatchLink: one missed 10s heartbeat plus slack. */
const STALE_AFTER_S = 15
const POLL_MS = 3000

export interface RoyaleLink {
  /** Seats whose player looks disconnected (said goodbye, or their heartbeat
   *  went quiet). Says nothing about WHY. */
  away: number[]
  /** THIS browser can't reach the server right now. */
  offline: boolean
}

const NONE: RoyaleLink = { away: [], offline: false }

/**
 * "Reconnecting..." for Battle Royale -- useMatchLink's twin. Polls
 * royale_link() while the match is live. Purely a notice: a player who stays
 * away is eliminated by the ordinary rule (two of their turns run out with no
 * action), which the chip in RoyaleMatch.tsx counts.
 */
export function useRoyaleLink(matchId: string | null, live: boolean, mySeat: number | null): RoyaleLink {
  const [link, setLink] = useState<RoyaleLink>(NONE)

  useEffect(() => {
    if (!matchId || !live) {
      setLink((l) => (l.away.length || l.offline ? NONE : l))
      return
    }
    let alive = true
    let failures = 0
    const tick = async () => {
      const rows = await royaleLink(matchId)
      if (!alive) return
      if (rows === null) {
        failures += 1
        if (failures >= 2 || !navigator.onLine) setLink((l) => (l.offline ? l : { ...l, offline: true }))
        return
      }
      failures = 0
      // Never report yourself as "away": if your own heartbeat is late, that
      // is your connection, and `offline` says so.
      const away = rows
        .filter((r) => r.seat !== mySeat && (r.away || r.age > STALE_AFTER_S))
        .map((r) => r.seat)
        .sort((a, b) => a - b)
      const next: RoyaleLink = { away, offline: !navigator.onLine }
      setLink((l) => (l.offline === next.offline && l.away.join() === next.away.join() ? l : next))
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
  }, [matchId, live, mySeat])

  return link
}
