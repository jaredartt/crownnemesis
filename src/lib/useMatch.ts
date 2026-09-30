import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from './supabase'
import { serverNow, sweepMatches, touchMatch } from './api'
import type { MatchRow, Message } from './types'

/**
 * Live view of one match.
 *
 * Realtime is the fast path. The 5-second poll underneath it is the safety
 * net: websockets drop on flaky wifi and on laptop sleep, and a turn-based
 * game that silently stops updating is the worst possible bug to debug. At
 * this player count the extra queries cost nothing.
 */
export function useMatch(matchId: string | null) {
  const [match, setMatch] = useState<MatchRow | null>(null)
  const [error, setError] = useState<string | null>(null)
  const seen = useRef<string>('')

  const pull = useCallback(async () => {
    if (!matchId) return
    const { data, error } = await supabase.from('matches').select('*').eq('id', matchId).maybeSingle()
    if (error) {
      setError(error.message)
      return
    }
    if (!data) return
    const row = data as MatchRow
    // A rematch swaps matchId under us while a request is in flight, and the
    // late answer would otherwise install the OLD finished room over the new
    // one -- and poison the ordering guard below with its timestamp.
    if (row.id !== matchId) return
    // Ignore stale rows that arrive out of order.
    if (row.updated_at >= seen.current) {
      seen.current = row.updated_at
      setMatch(row)
    }
  }, [matchId])

  useEffect(() => {
    if (!matchId) {
      setMatch(null)
      return
    }
    seen.current = ''
    pull()

    const channel = supabase
      .channel(`match:${matchId}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'matches', filter: `id=eq.${matchId}` },
        (payload) => {
          const row = payload.new as MatchRow

          // A REALTIME ROW IS A HINT, NOT THE TRUTH.
          //
          // This is what the white screen was. `matches.state` is `jsonb not
          // null`, so the database never holds a match without a board -- but
          // the row that arrives down the websocket is not always the whole
          // row. Realtime has a payload cap, and a message over it arrives
          // with the offending columns MISSING and an `errors` field set. The
          // state blob is by far the largest column and it GROWS ALL MATCH
          // (the log is appended to for ever), so the first message to go over
          // the cap is the one carrying the biggest single addition -- an
          // exchange, which adds an fx with its whole list of swings and two
          // log lines at once. Which is exactly the report: it goes white when
          // you attack, in a match that has been going a while, on every
          // device, and never in a fresh one.
          //
          // Installing that row put `match.state === undefined` into a screen
          // that had every right to assume otherwise, and the first thing to
          // touch it threw. So: a message that does not carry a whole row is
          // treated as what it actually is -- news that SOMETHING changed --
          // and the row is fetched. The poll underneath would have healed it
          // within five seconds anyway; this just does not wait, and does not
          // crash in the meantime.
          //
          // Deliberately not "patch the missing fields from the old row": a
          // half-row merged into a whole one is a board from one moment and a
          // status from another, which is a worse bug than this one and much
          // harder to see.
          if (!row || !row.state || !row.updated_at) {
            if (import.meta.env.DEV) {
              console.warn('[match] partial realtime row, refetching', payload)
            }
            void pull()
            return
          }

          if (row.updated_at >= seen.current) {
            seen.current = row.updated_at
            setMatch(row)
          }
        },
      )
      .subscribe()

    // Heartbeat: this is what keeps the room from being swept. Sent
    // immediately so a freshly opened room is never a candidate, then every
    // ten seconds against a 45-second grace -- three misses before a room is
    // considered empty, which survives a refresh or a phone waking up.
    touchMatch(matchId)
    const beat = setInterval(() => touchMatch(matchId), 10_000)

    // 0175: a player who has walked away (closed the tab, lost their
    // connection) is forfeited by sweep_matches() once they have been silent
    // for abandon_grace(). The database also runs it on a 30-second timer;
    // asking from here too means the player who stayed sees their victory
    // within seconds of the grace ending rather than up to half a minute
    // later. Safe from anyone, players and spectators alike: it only ever
    // acts on a heartbeat that really has gone quiet.
    const sweeper = setInterval(() => { void sweepMatches() }, 15_000)

    const poll = setInterval(pull, 5000)
    return () => {
      supabase.removeChannel(channel)
      clearInterval(poll)
      clearInterval(beat)
      clearInterval(sweeper)
    }
  }, [matchId, pull])

  return { match, error, refresh: pull }
}

export function useMessages(matchId: string | null) {
  const [messages, setMessages] = useState<Message[]>([])

  useEffect(() => {
    if (!matchId) {
      setMessages([])
      return
    }
    let alive = true
    supabase
      .from('match_messages')
      .select('*')
      .eq('match_id', matchId)
      .order('created_at', { ascending: true })
      .limit(200)
      .then(({ data }) => {
        if (alive && data) setMessages(data as Message[])
      })

    const channel = supabase
      .channel(`chat:${matchId}`)
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'match_messages', filter: `match_id=eq.${matchId}` },
        (payload) => {
          const msg = payload.new as Message
          setMessages((prev) => (prev.some((m) => m.id === msg.id) ? prev : [...prev, msg]))
        },
      )
      .subscribe()

    return () => {
      alive = false
      supabase.removeChannel(channel)
    }
  }, [matchId])

  return messages
}

/** Offset between this browser's clock and Postgres's, so the countdown is
 *  honest even if the user's laptop clock is minutes off. */
export function useServerClock() {
  const [offset, setOffset] = useState(0)
  useEffect(() => {
    let alive = true
    const sync = async () => {
      const t0 = Date.now()
      const server = await serverNow()
      const rtt = Date.now() - t0
      if (alive) setOffset(server + rtt / 2 - Date.now())
    }
    sync()
    const id = setInterval(sync, 60_000)
    return () => {
      alive = false
      clearInterval(id)
    }
  }, [])
  return offset
}
