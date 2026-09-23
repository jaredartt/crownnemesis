import { useState } from 'react'
import { useAppSettings, setFriendTournamentLpEnabled } from '../lib/useAppSettings'

/**
 * The one setting this tab holds: whether a 1v1 friend-room or tournament
 * match also moves ladder points when it finishes, the same as ranked
 * matchmaking already does. Temporary, per Jared -- flippable here at any
 * time, and it takes effect immediately (no reload, no deploy): the three
 * server-side places a match can end (claim_win, cn_finish, cn_attack's own
 * win branch, and advance_turn's AFK-forfeit branch -- see
 * 0066/0067/0068_*.sql) all read this same row fresh, at the moment each
 * match actually finishes, rather than baking it into the match at creation.
 *
 * A bot match never counts, whatever this is set to -- that exclusion is
 * unconditional on the server and this tab does not offer a way around it.
 * Battle Royale is untouched: it has no ranked column and never calls
 * finish_match at all, so there is nothing here that could apply to it.
 */
export function AdminLadder() {
  const settings = useAppSettings()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  async function toggle(v: boolean) {
    setBusy(true); setErr(null)
    try { await setFriendTournamentLpEnabled(v) }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  return (
    <div className="admin-ladder">
      <label className="admin-flag">
        <input
          type="checkbox"
          checked={settings.friend_and_tournament_lp_enabled}
          disabled={busy}
          onChange={(e) => void toggle(e.target.checked)}
        />
        <span>Award ladder points for 1v1 friend matches and tournaments</span>
      </label>
      <p className="muted tiny">
        Off by default. Ranked matchmaking always awards RP regardless of this
        setting; bot matches never do. Battle Royale is not affected. Takes
        effect immediately for every match still in progress, not just new
        ones started after you flip it.
      </p>
      {err && <p className="error tiny">{err}</p>}
    </div>
  )
}
