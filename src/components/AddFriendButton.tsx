import { useState } from 'react'
import { sendFriendRequest } from '../lib/api'
import { useT } from '../lib/i18n'
import { refreshFriends, useFriends } from '../lib/useFriends'
import { IconCheck, IconPersonPlus } from './Icons'

/**
 * The small "+person" that follows another player's name wherever it shows
 * up as a clickable identity -- a Ladder row, an opponent's name after a
 * match. Reads the same cached friends state Friends.tsx does, so a dozen
 * of these on the Ladder cost one fetch between them, not one each.
 *
 * Renders nothing for your own row, and nothing once you are already
 * friends -- there is nothing left to offer there. Renders a plain check,
 * disabled, once a request is pending, rather than disappearing: a button
 * that vanishes on the tap that used it reads as a mistake.
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
  if (friends.some((f) => f.friend_id === targetId)) return null
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
      type="button" className="addfriend-btn" disabled={busy || pending}
      onClick={add}
      aria-label={t('friends.addFriend')}
      title={err ?? (pending ? t('friends.requestPending') : t('friends.addFriend'))}
    >
      {pending ? <IconCheck /> : <IconPersonPlus />}
    </button>
  )
}
