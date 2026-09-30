import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from './supabase'
import { sendRoyaleGoingAway, sweepRoyaleMatches, touchRoyaleMatch } from './api'
import type { RoyaleMatchRow, RoyaleMessage, RoyalePlayerRow } from './types'

/**
 * Live view of one royale match. Same realtime-plus-poll-plus-heartbeat
 * idiom as useMatch() in useMatch.ts -- see that file's long comment for why
 * a partial realtime row is treated as a hint rather than the truth. Kept as
 * its own hook (rather than a generic one both call) so nothing about the
 * 1v1 hook risks moving while this ships.
 */
export function useRoyaleMatch(matchId: string | null) {
  const [match, setMatch] = useState<RoyaleMatchRow | null>(null)
  const [error, setError] = useState<string | null>(null)
  const seen = useRef<string>('')

  const pull = useCallback(async () => {
    if (!matchId) return
    const { data, error } = await supabase
      .from('royale_matches').select('*').eq('id', matchId).maybeSingle()
    if (error) {
      setError(error.message)
      return
    }
    if (!data) return
    const row = data as RoyaleMatchRow
    if (row.id !== matchId) return
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
      .channel(`royale:${matchId}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'royale_matches', filter: `id=eq.${matchId}` },
        (payload) => {
          const row = payload.new as RoyaleMatchRow
          if (!row || !row.state || !row.updated_at) {
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

    touchRoyaleMatch(matchId)
    const beat = setInterval(() => touchRoyaleMatch(matchId), 10_000)
    // Fast path for the server-side sweep (pg_cron runs it every 15s anyway):
    // expires a turn clock that has really run out and drops a seat that has
    // vanished, even when nobody at the table is looking. Safe from anyone.
    const sweeper = setInterval(() => { void sweepRoyaleMatches() }, 15_000)

    // "Reconnecting..." hints, same as 1v1's useMatch: say goodbye the moment
    // this page goes away, say we're back the moment it returns.
    const goodbye = () => sendRoyaleGoingAway(matchId)
    const back = () => { if (document.visibilityState === 'visible') touchRoyaleMatch(matchId) }
    window.addEventListener('pagehide', goodbye)
    window.addEventListener('pageshow', back)
    document.addEventListener('visibilitychange', back)

    const poll = setInterval(pull, 5000)
    return () => {
      supabase.removeChannel(channel)
      clearInterval(poll)
      clearInterval(beat)
      clearInterval(sweeper)
      window.removeEventListener('pagehide', goodbye)
      window.removeEventListener('pageshow', back)
      document.removeEventListener('visibilitychange', back)
    }
  }, [matchId, pull])

  return { match, error, refresh: pull }
}

/** The seat list -- who is in, who is eliminated, who is ready. Its own
 *  table (royale_players), its own realtime subscription: it changes on
 *  join/ready/eliminate, none of which necessarily touch the match row's
 *  `updated_at` at the same instant. */
export function useRoyalePlayers(matchId: string | null) {
  const [players, setPlayers] = useState<RoyalePlayerRow[]>([])

  const pull = useCallback(async () => {
    if (!matchId) return
    // 0060: a HUMAN seat's name_color is embedded live via the
    // user_id -> profiles FK rather than read off this table's own column
    // (see RoyalePlayerRow's own comment) -- safe to join, unlike
    // royale_messages: every change below re-runs this whole query rather
    // than merging a bare realtime payload, so the join never goes stale.
    // A bot seat's user_id is null, so that join comes back null -- 0098
    // gave the row its own name_color column for exactly that case (same
    // shape as `avatar`, already read straight off the row), so a bot
    // falls back to it here.
    const { data } = await supabase
      .from('royale_players')
      .select('*, profiles(name_color, equipped_unit_skin, equipped_frame)')
      .eq('match_id', matchId).order('seat')
    if (data) {
      setPlayers((data as unknown as (RoyalePlayerRow & { profiles: { name_color: string | null; equipped_unit_skin: string | null; equipped_frame: string | null } | null })[])
        .map((row) => ({
          ...row,
          name_color: row.profiles?.name_color ?? row.name_color ?? null,
          equipped_unit_skin: row.profiles?.equipped_unit_skin ?? null,
          equipped_frame: row.profiles?.equipped_frame ?? null,
        })))
    }
  }, [matchId])

  useEffect(() => {
    if (!matchId) {
      setPlayers([])
      return
    }
    pull()
    const channel = supabase
      .channel(`royale-players:${matchId}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'royale_players', filter: `match_id=eq.${matchId}` },
        () => void pull(),
      )
      .subscribe()
    const poll = setInterval(pull, 5000)
    return () => {
      supabase.removeChannel(channel)
      clearInterval(poll)
    }
  }, [matchId, pull])

  return players
}

export function useRoyaleMessages(matchId: string | null) {
  const [messages, setMessages] = useState<RoyaleMessage[]>([])

  useEffect(() => {
    if (!matchId) {
      setMessages([])
      return
    }
    let alive = true
    supabase
      .from('royale_messages')
      .select('*')
      .eq('match_id', matchId)
      .order('created_at', { ascending: true })
      .limit(200)
      .then(({ data }) => {
        if (alive && data) setMessages(data as RoyaleMessage[])
      })

    const channel = supabase
      .channel(`royale-chat:${matchId}`)
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'royale_messages', filter: `match_id=eq.${matchId}` },
        (payload) => {
          const msg = payload.new as RoyaleMessage
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
