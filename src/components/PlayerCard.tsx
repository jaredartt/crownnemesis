import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { joinMatch, removeFriend, sendFriendRequest, sendMatchInvite } from '../lib/api'
import { ACHIEVEMENTS_BY_ID } from '../lib/achievements'
import { inviteCooldownMs, noteInviteSent } from '../lib/inviteCooldown'
import { nameColorStyle } from '../lib/nameColors'
import type { Profile } from '../lib/types'
import { useT } from '../lib/i18n'
import { isOnline, refreshFriends, useFriends } from '../lib/useFriends'
import { Avatar } from './Avatar'
import { Modal } from './Modal'

interface PlayerRow {
  id: string
  username: string
  avatar: string | null
  name_color?: string
  rating: number
  wins: number
  losses: number
  games: number
  streak: number
  tournaments?: number
}

/**
 * Somebody else's card: a Ladder row or a name in the friends list, opened
 * up. Jared: "if you click an account in the ladder page, a pop-up will
 * appear with their profile pic, username with its color, their
 * achievements they selected, their W, their strike, their cups, if
 * they're online, also the ability to send them an invite to play 1 vs 1,
 * to add them as friends, remove from friends."
 *
 * Read-only about them (this is not ProfileCard -- nothing here is
 * editable) plus the three things you can actually DO about another
 * account: invite, add, remove. Stats come from `leaderboard`, the exact
 * view the Ladder table itself reads, so a number here always matches the
 * row that opened it. Achievements and online status are the two things
 * `leaderboard` doesn't carry -- the first is its own tiny query
 * (featured_achievements lives on `profiles`, not the view), the second
 * only exists for a friend at all (user_presence's own RLS -- see
 * useFriends.ts -- keeps a stranger's presence off this screen entirely
 * rather than half-showing it).
 */
export function PlayerCard({ userId, me, onClose, onEnter }: {
  userId: string
  me: Profile
  onClose: () => void
  /** Same shape every "walk into the room you just invited yourself into"
   *  caller already uses (Friends.tsx's own invite(), NotificationsBell). */
  onEnter: (matchId: string) => void
}) {
  const t = useT()
  const { friends, outgoing, presence } = useFriends(me.id)
  const [row, setRow] = useState<PlayerRow | null>(null)
  const [achievements, setAchievements] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [cooldown, setCooldown] = useState(() => inviteCooldownMs(userId))
  const [confirmRemove, setConfirmRemove] = useState(false)

  useEffect(() => {
    let alive = true
    setRow(null); setAchievements([]); setErr(null); setConfirmRemove(false)
    Promise.all([
      supabase.from('leaderboard').select('*').eq('id', userId).maybeSingle(),
      supabase.from('profiles').select('featured_achievements').eq('id', userId).maybeSingle(),
    ]).then(([lb, pf]) => {
      if (!alive) return
      if (lb.data) setRow(lb.data as PlayerRow)
      const feat = (pf.data as { featured_achievements?: string[] } | null)?.featured_achievements
      setAchievements(feat ?? [])
    })
    return () => { alive = false }
  }, [userId])

  // A live countdown rather than a value set once on mount -- opening this
  // card a few minutes into somebody else's cooldown should still show the
  // time actually left, and the button should un-grey itself the moment it
  // reaches zero without the card having to be closed and reopened.
  useEffect(() => {
    if (cooldown <= 0) return
    const id = setInterval(() => setCooldown(inviteCooldownMs(userId)), 1000)
    return () => clearInterval(id)
  }, [cooldown, userId])

  const isSelf = userId === me.id
  const isFriend = friends.some((f) => f.friend_id === userId)
  const pending = outgoing.some((r) => r.to_id === userId)
  const online = isOnline(presence[userId])

  async function invite() {
    setBusy(true); setErr(null)
    try {
      const code = await sendMatchInvite(userId, '1v1')
      noteInviteSent(userId)
      setCooldown(inviteCooldownMs(userId))
      const m = await joinMatch(code)
      onEnter(m.id)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function addFriend() {
    setBusy(true); setErr(null)
    try { await sendFriendRequest(userId); await refreshFriends(me.id) }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  async function unfriend() {
    setBusy(true); setErr(null)
    try { await removeFriend(userId); await refreshFriends(me.id) }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(false); setConfirmRemove(false) }
  }

  return (
    <Modal title={row?.username ?? '…'} onClose={onClose}>
      <div className="playercard">
        <div className="playercard-head">
          <Avatar slug={row?.avatar} name={row?.username ?? '?'} size={72} className="is-big" />
          <span className="playercard-name" style={nameColorStyle(row?.name_color)}>
            {row?.username ?? '…'}
          </span>
          {isFriend && (
            <span className="playercard-presence">
              <span className={`presence-dot${online ? ' is-on' : ''}`} aria-hidden="true" />
              {online ? t('common.online') : t('common.offline')}
            </span>
          )}
        </div>

        {row && (
          <div className="playercard-stats">
            <div className="playercard-stat">
              <span className="playercard-statval">{row.rating}</span>
              <span className="playercard-statlabel">{t('ladder.lp')}</span>
            </div>
            <div className="playercard-stat">
              <span className="playercard-statval">{row.wins}</span>
              <span className="playercard-statlabel">{t('ladder.w')}</span>
            </div>
            <div className="playercard-stat">
              <span className={`playercard-statval${row.streak > 0 ? ' is-up' : row.streak < 0 ? ' is-down' : ''}`}>
                {row.streak > 0 ? `${row.streak}${t('ladder.w')}`
                  : row.streak < 0 ? `${-row.streak}${t('ladder.l')}` : '0'}
              </span>
              <span className="playercard-statlabel">{t('ladder.streak')}</span>
            </div>
            <div className="playercard-stat">
              <span className="playercard-statval">
                {row.tournaments ? row.tournaments : t('common.dash')}
              </span>
              <span className="playercard-statlabel">{t('ladder.cups')}</span>
            </div>
          </div>
        )}

        <h3 className="pf-title">{t('achievements.title')}</h3>
        {achievements.length > 0 ? (
          <div className="playercard-achs">
            {achievements.map((id) => {
              const a = ACHIEVEMENTS_BY_ID.get(id)
              if (!a) return null
              return (
                <span key={id} className="playercard-ach" title={t(a.descKey, { n: a.threshold })}>
                  <span aria-hidden="true">{a.icon}</span>
                  {t(a.nameKey, { n: a.threshold })}
                </span>
              )
            })}
          </div>
        ) : (
          <p className="muted tiny">{t('player.noAchievements')}</p>
        )}

        {!isSelf && (
          <div className="actionbar playercard-acts">
            <button className="btn primary" disabled={busy || cooldown > 0} onClick={invite}>
              {cooldown > 0
                ? t('player.inviteCooldown', { n: Math.ceil(cooldown / 60000) })
                : t('player.invite1v1')}
            </button>
            {isFriend ? (
              confirmRemove ? (
                <button className="btn danger" disabled={busy} onClick={unfriend}>
                  {t('friends.removeConfirm', { name: row?.username ?? '' })}
                </button>
              ) : (
                <button className="btn ghost" disabled={busy} onClick={() => setConfirmRemove(true)}>
                  {t('friends.removeFriend')}
                </button>
              )
            ) : (
              <button className="btn ghost" disabled={busy || pending} onClick={addFriend}>
                {pending ? t('friends.requestPending') : t('friends.addFriend')}
              </button>
            )}
          </div>
        )}
        {err && <p className="error">{err}</p>}
      </div>
    </Modal>
  )
}
