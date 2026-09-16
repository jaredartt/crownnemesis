import { useEffect, useRef, useState } from 'react'
import {
  joinMatch, joinRoyaleMatch, markAllNotificationsRead, markNotificationRead, respondFriendRequest,
} from '../lib/api'
import { useT } from '../lib/i18n'
import { timeAgo } from '../lib/timeAgo'
import type { NotificationRow, Profile } from '../lib/types'
import { refreshFriends, useFriends } from '../lib/useFriends'
import { useNotifications } from '../lib/useNotifications'
import { IconBell, IconCheck, IconClose } from './Icons'

/**
 * The bell in the menu header. A popover, not a Modal -- Modal dims and
 * blurs the whole screen for something you are meant to glance at and keep
 * playing, the same reasoning ProfileCard's own overlay does NOT apply here.
 */
export function NotificationsBell({ profile, onJoinMatch, onOpenTournament, onJoinRoyale }: {
  profile: Profile
  onJoinMatch: (matchId: string) => void
  onOpenTournament: () => void
  onJoinRoyale: (matchId: string) => void
}) {
  const t = useT()
  const rows = useNotifications(profile.id)
  const { incoming } = useFriends(profile.id)
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)
  const boxRef = useRef<HTMLDivElement>(null)
  const btnRef = useRef<HTMLButtonElement>(null)

  const unread = rows.some((n) => !n.read)

  useEffect(() => {
    if (!open) return
    const onDoc = (e: MouseEvent) => {
      const t_ = e.target as Node
      if (boxRef.current?.contains(t_) || btnRef.current?.contains(t_)) return
      setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onDoc)
    window.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDoc)
      window.removeEventListener('keydown', onKey)
    }
  }, [open])

  function toggle() {
    setOpen((o) => {
      const next = !o
      if (next && unread) void markAllNotificationsRead()
      return next
    })
  }

  function message(n: NotificationRow): string {
    const name = n.payload.from_username ?? n.payload.by_username ?? '…'
    if (n.type === 'friend_request') return t('notif.friendRequest', { name })
    if (n.type === 'friend_accepted') return t('notif.friendAccepted', { name })
    // n.type === 'match_invite'
    if (n.payload.mode === 'tournament') return t('notif.matchInviteTournament', { name })
    if (n.payload.mode === '4p') return t('notif.matchInvite4p', { name })
    return t('notif.matchInvite1v1', { name })
  }

  async function respond(n: NotificationRow, accept: boolean) {
    const id = n.payload.request_id
    if (!id) return
    setBusy(n.id)
    try {
      await respondFriendRequest(id, accept)
      await refreshFriends(profile.id)
      await markNotificationRead(n.id)
    } finally {
      setBusy(null)
    }
  }

  async function acceptInvite(n: NotificationRow) {
    setBusy(n.id)
    try {
      if (n.payload.mode === 'tournament') {
        onOpenTournament()
      } else if (n.payload.mode === '4p' && n.payload.code) {
        const m = await joinRoyaleMatch(n.payload.code)
        onJoinRoyale(m.id)
      } else if (n.payload.mode === '1v1' && n.payload.code) {
        const m = await joinMatch(n.payload.code)
        onJoinMatch(m.id)
      }
      await markNotificationRead(n.id)
      setOpen(false)
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="bellwrap">
      <button
        ref={btnRef} className="iconbtn bellbtn" onClick={toggle}
        aria-label={t('notif.title')}
      >
        <IconBell />
        {unread && <span className="bell-dot" aria-hidden="true" />}
      </button>
      {open && (
        <div className="bellpanel" ref={boxRef} role="dialog" aria-label={t('notif.title')}>
          <header className="bellpanel-head">
            <h3>{t('notif.title')}</h3>
          </header>
          {rows.length === 0 && <p className="muted tiny bellpanel-empty">{t('notif.empty')}</p>}
          <ul className="bellpanel-list">
            {rows.map((n) => (
              <li key={n.id} className={`bellrow${n.read ? '' : ' is-unread'}`}>
                <p className="bellrow-msg">{message(n)}</p>
                <span className="bellrow-time">{timeAgo(n.created_at, t)}</span>
                {n.type === 'friend_request'
                  && incoming.some((r) => r.id === n.payload.request_id) && (
                  <span className="bellrow-acts">
                    <button
                      className="btn tiny primary" disabled={busy === n.id}
                      onClick={() => respond(n, true)} aria-label={t('common.accept')}
                    >
                      <IconCheck />
                    </button>
                    <button
                      className="btn tiny ghost" disabled={busy === n.id}
                      onClick={() => respond(n, false)} aria-label={t('common.decline')}
                    >
                      <IconClose />
                    </button>
                  </span>
                )}
                {n.type === 'match_invite' && (
                  <span className="bellrow-acts">
                    <button
                      className="btn tiny primary" disabled={busy === n.id}
                      onClick={() => acceptInvite(n)}
                    >
                      {n.payload.mode === 'tournament' ? t('notif.goToTournament') : t('common.join')}
                    </button>
                  </span>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
