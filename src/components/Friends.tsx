import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import {
  joinMatch, joinRoyaleMatch, removeFriend, respondFriendRequest, sendFriendRequest,
  sendMatchInvite,
} from '../lib/api'
import type { Profile } from '../lib/types'
import { useT } from '../lib/i18n'
import { isOnline, refreshFriends, useFriends } from '../lib/useFriends'
import { Avatar } from './Avatar'
import { nameColorStyle } from '../lib/nameColors'
import { IconCheck, IconClose, IconPersonPlus } from './Icons'

/**
 * The Friends tile's new primary content: who you know, who just asked, and
 * a way to find someone you don't know yet. The code-share room this used to
 * be the whole of stays mounted below it (see Lobby.tsx) -- a five-letter
 * code is still the fastest way to play somebody who isn't a friend yet.
 */
export function Friends({ profile, onEnter, onEnterRoyale, onViewPlayer }: {
  profile: Profile
  onEnter: (matchId: string) => void
  onEnterRoyale: (matchId: string) => void
  /** Opens PlayerCard for a row's own account -- omitted (Vs Friends still
   *  embeds this component without it) rather than every row silently
   *  growing a click handler nobody asked for there. */
  onViewPlayer?: (id: string) => void
}) {
  const t = useT()
  const { friends, incoming, outgoing, presence } = useFriends(profile.id)

  const [names, setNames] = useState<Record<string, Profile>>({})
  const friendIds = useMemo(() => friends.map((f) => f.friend_id), [friends])
  const wantedIds = useMemo(() => {
    const ids = new Set(friendIds)
    incoming.forEach((r) => ids.add(r.from_id))
    outgoing.forEach((r) => ids.add(r.to_id))
    return Array.from(ids)
  }, [friendIds, incoming, outgoing])

  // One fetch for every profile this screen needs a name and face for --
  // friends, and whoever is on the other end of a pending request. Refetches
  // whenever the id list actually changes, not on every render.
  useEffect(() => {
    if (wantedIds.length === 0) { setNames({}); return }
    let alive = true
    supabase.from('profiles').select('*').in('id', wantedIds)
      .then(({ data }) => {
        if (!alive || !data) return
        const map: Record<string, Profile> = {}
        for (const p of data as Profile[]) map[p.id] = p
        setNames(map)
      })
    return () => { alive = false }
  }, [wantedIds.join(',')])

  const [busy, setBusy] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null)

  async function respond(id: string, accept: boolean) {
    setBusy(id); setErr(null)
    try { await respondFriendRequest(id, accept); await refreshFriends(profile.id) }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(null) }
  }

  async function remove(id: string) {
    setBusy(id); setErr(null)
    try { await removeFriend(id); await refreshFriends(profile.id) }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(null); setConfirmRemove(null) }
  }

  async function invite(id: string, mode: '1v1' | '4p' | 'tournament') {
    setBusy(id); setErr(null); setNote(null)
    try {
      const code = await sendMatchInvite(id, mode)
      if (mode === '1v1') {
        // The room already exists -- create_match() made it inside
        // send_match_invite -- and join_match() simply hands the host back
        // their own room rather than erroring, so this is how the inviter
        // walks into the match they just opened for their friend.
        const m = await joinMatch(code)
        onEnter(m.id)
        return
      }
      if (mode === '4p') {
        // Same shape, for the royale room send_match_invite's '4p' branch
        // just opened via create_royale_match() -- walk the inviter into
        // their own seat 0.
        const m = await joinRoyaleMatch(code)
        onEnterRoyale(m.id)
        return
      }
      setNote(t('friends.inviteSent'))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(null)
    }
  }

  // ---- search ---------------------------------------------------------
  const [q, setQ] = useState('')
  const [results, setResults] = useState<Profile[]>([])
  const [searching, setSearching] = useState(false)

  const search = useCallback(async () => {
    const query = q.trim()
    if (!query) { setResults([]); return }
    setSearching(true); setErr(null)
    const { data, error } = await supabase
      .from('profiles').select('*')
      .ilike('username', `%${query}%`)
      .neq('id', profile.id)
      .order('username')
      .limit(20)
    setSearching(false)
    if (error) { setErr(error.message); return }
    setResults((data ?? []) as Profile[])
  }, [q, profile.id])

  async function add(id: string) {
    setBusy(id); setErr(null); setNote(null)
    try {
      await sendFriendRequest(id)
      await refreshFriends(profile.id)
      setNote(t('friends.requestSent'))
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(null)
    }
  }

  const friendSet = new Set(friendIds)
  const outgoingSet = new Set(outgoing.map((r) => r.to_id))

  return (
    <div className="friends">
      {incoming.length > 0 && (
        <div className="friends-section">
          <h3 className="friends-heading">{t('friends.pendingRequests')}</h3>
          <ul className="friends-list">
            {incoming.map((r) => {
              const p = names[r.from_id]
              return (
                <li key={r.id} className="friends-row">
                  <Avatar slug={p?.avatar} name={p?.username ?? '?'} size={32} />
                  <span className="friends-name">
                    {t('friends.requestFrom', { name: p?.username ?? '…' })}
                  </span>
                  <span className="friends-acts">
                    <button
                      className="btn small primary" disabled={busy === r.id}
                      onClick={() => respond(r.id, true)} aria-label={t('common.accept')}
                    >
                      <IconCheck />
                    </button>
                    <button
                      className="btn small ghost" disabled={busy === r.id}
                      onClick={() => respond(r.id, false)} aria-label={t('common.decline')}
                    >
                      <IconClose />
                    </button>
                  </span>
                </li>
              )
            })}
          </ul>
        </div>
      )}

      {/* Jared: "Add friend section should be on top of your friends
          section." Pending requests (above, when there are any) stays
          first either way -- something waiting on YOU to answer outranks
          both. */}
      <div className="friends-section">
        <h3 className="friends-heading">{t('friends.addFriend')}</h3>
        <form
          className="friends-search" onSubmit={(e) => { e.preventDefault(); void search() }}
        >
          <input
            value={q} onChange={(e) => setQ(e.target.value)}
            placeholder={t('friends.searchPlaceholder')}
          />
          <button className="btn small" disabled={searching}>
            {searching ? t('friends.searching') : t('friends.search')}
          </button>
        </form>
        {results.length > 0 && (
          <ul className="friends-list">
            {results.map((p) => {
              const already = friendSet.has(p.id)
              const pending = outgoingSet.has(p.id)
              return (
                <li key={p.id} className="friends-row">
                  {onViewPlayer ? (
                    <button
                      type="button" className="friends-whoclick"
                      onClick={() => onViewPlayer(p.id)}
                    >
                      <Avatar slug={p.avatar} name={p.username} size={32} />
                      <span className="friends-name" style={nameColorStyle(p.name_color)}>{p.username}</span>
                    </button>
                  ) : (
                    <>
                      <Avatar slug={p.avatar} name={p.username} size={32} />
                      <span className="friends-name" style={nameColorStyle(p.name_color)}>{p.username}</span>
                    </>
                  )}
                  <span className="friends-acts">
                    <button
                      className="btn small" disabled={already || pending || busy === p.id}
                      onClick={() => add(p.id)}
                    >
                      <IconPersonPlus />
                      {already ? t('friends.alreadyFriends')
                        : pending ? t('friends.requestPending') : t('friends.addFriend')}
                    </button>
                  </span>
                </li>
              )
            })}
          </ul>
        )}
        {q.trim() && !searching && results.length === 0 && (
          <p className="muted tiny">{t('friends.noResults')}</p>
        )}
      </div>

      <div className="friends-section">
        <h3 className="friends-heading">{t('friends.yourFriends')}</h3>
        {friends.length === 0 && <p className="muted tiny">{t('friends.noFriendsYet')}</p>}
        <ul className="friends-list">
          {friends.map((f) => {
            const p = names[f.friend_id]
            const online = isOnline(presence[f.friend_id])
            return (
              <li key={f.friend_id} className="friends-row">
                <span className={`presence-dot ${online ? 'is-on' : ''}`} aria-hidden="true" />
                {onViewPlayer ? (
                  <button
                    type="button" className="friends-whoclick"
                    onClick={() => onViewPlayer(f.friend_id)}
                  >
                    <Avatar slug={p?.avatar} name={p?.username ?? '?'} size={32} />
                    <span className="friends-name">
                      <span style={nameColorStyle(p?.name_color)}>{p?.username ?? '…'}</span>
                      <span className="friends-presence muted tiny">
                        {online ? t('common.online') : t('common.offline')}
                      </span>
                    </span>
                  </button>
                ) : (
                  <>
                    <Avatar slug={p?.avatar} name={p?.username ?? '?'} size={32} />
                    <span className="friends-name">
                      <span style={nameColorStyle(p?.name_color)}>{p?.username ?? '…'}</span>
                      <span className="friends-presence muted tiny">
                        {online ? t('common.online') : t('common.offline')}
                      </span>
                    </span>
                  </>
                )}
                <span className="friends-acts">
                  <button
                    className="btn tiny" disabled={busy === f.friend_id}
                    onClick={() => invite(f.friend_id, '1v1')}
                  >
                    {t('friends.invite1v1')}
                  </button>
                  <button
                    className="btn tiny" disabled={busy === f.friend_id}
                    onClick={() => invite(f.friend_id, '4p')}
                  >
                    {t('friends.invite4p')}
                  </button>
                  <button
                    className="btn tiny" disabled={busy === f.friend_id}
                    onClick={() => invite(f.friend_id, 'tournament')}
                  >
                    {t('friends.inviteTournament')}
                  </button>
                  {confirmRemove === f.friend_id ? (
                    <button
                      className="btn tiny danger" disabled={busy === f.friend_id}
                      onClick={() => remove(f.friend_id)}
                    >
                      {t('common.remove')}?
                    </button>
                  ) : (
                    <button
                      className="btn tiny ghost"
                      onClick={() => setConfirmRemove(f.friend_id)}
                    >
                      {t('common.remove')}
                    </button>
                  )}
                </span>
              </li>
            )
          })}
        </ul>
      </div>

      {note && <p className="notice">{note}</p>}
      {err && <p className="error">{err}</p>}
    </div>
  )
}
