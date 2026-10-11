import { useState } from 'react'
import { sendFriendRequest } from '../lib/api'
import { useT } from '../lib/i18n'
import { refreshFriends, useFriends } from '../lib/useFriends'
import { IconPersonCheck, IconPersonClock, IconPersonPlus } from './Icons'

/**
 * The small "+person" that follows another player's name wherever it shows
 * up as a clickable identity -- a Ladder row, an opponent's name after a
 * match. Reads the same cached friends state Friends.tsx does, so a dozen
 * of these on the Ladder cost one fetch between them, not one each.
 *
 * Renders nothing for your own row. Three states for everybody else:
 * "+person" (add), "person + clock" (request sent, disabled) and, once you
 * are already friends, a green "person + check" (disabled). Jared: a plain
 * check did not say "friends" -- and it was in fact the PENDING state, so it
 * was being read as the wrong thing. Neither state disappears: a button that
 * vanishes on the tap that used it reads as a mistake.
 */
export function AddFriendButton({ userId, targetId }: {
  userId: string
  targetId: string
}) {
  const t = useT()
  const { friends, outgoing } = useFriends(userId)
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  if (targetId === userId) return null
  const isFriend = friends.some((f) => f.friend_id === targetId)
  const pending = sent || outgoing.some((r) => r.to_id === targetId)

  async function add() {
    setBusy(true); setErr(null)
    try {
      await sendFriendRequest(targetId)
      await refreshFriends(userId)
      setSent(true)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <button
      type="button" className={`addfriend-btn${isFriend ? ' is-friend' : pending ? ' is-pending' : ''}`}
      disabled={busy || pending || isFriend}
      onClick={add}
      aria-label={isFriend ? t('friends.alreadyFriends') : pending ? t('friends.requestPending') : t('friends.addFriend')}
      title={err ?? (isFriend ? t('friends.alreadyFriends') : pending ? t('friends.requestPending') : t('friends.addFriend'))}
    >
      {isFriend ? <IconPersonCheck /> : pending ? <IconPersonClock /> : <IconPersonPlus />}
    </button>
  )
}
