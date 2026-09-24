import { useEffect, useState } from 'react'
import {
  useAppSettings, setFriendTournamentLpEnabled, setEloSettings, setRankedBotAfterSeconds,
} from '../lib/useAppSettings'
import { expectedScore, nextRating } from '../lib/rating'

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
 *
 * 0082 added the second half of this tab: the ranked Elo K-factor. Same
 * live-immediately shape as the toggle above -- cn_elo_k() reads this same
 * app_settings row fresh every time finish_match() runs, so a change here
 * needs no redeploy and applies to the very next match that finishes.
 *
 * bot_identity_and_ranked_fallback added the third: how long ranked
 * matchmaking waits for a real opponent before pairing you with a bot
 * instead. Jared: "make it so that I can adjust how many seconds a player
 * needs to wait without not finding a real player so that they fight a bot,
 * give me the control from the admin page." Same shape again -- ranked_tick()
 * reads this row fresh on every queue tick, so a change here needs no
 * redeploy either.
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

  // Local drafts for the three K-factor fields -- committed on blur/submit
  // rather than on every keystroke, the same reason any number input in
  // this codebase debounces itself (AdminCards does the identical thing).
  // Reset from `settings` whenever it changes underneath us (another admin
  // tab, or this same one after a save) and the field isn't mid-edit.
  const [placement, setPlacement] = useState(String(settings.elo_k_placement))
  const [established, setEstablished] = useState(String(settings.elo_k_established))
  const [placementGames, setPlacementGames] = useState(String(settings.elo_placement_games))
  const [eloBusy, setEloBusy] = useState(false)
  const [eloErr, setEloErr] = useState<string | null>(null)
  const [dirty, setDirty] = useState(false)

  useEffect(() => {
    if (dirty) return
    setPlacement(String(settings.elo_k_placement))
    setEstablished(String(settings.elo_k_established))
    setPlacementGames(String(settings.elo_placement_games))
  }, [settings.elo_k_placement, settings.elo_k_established, settings.elo_placement_games, dirty])

  async function saveElo() {
    const p = Math.max(1, Math.round(Number(placement)) || settings.elo_k_placement)
    const e = Math.max(1, Math.round(Number(established)) || settings.elo_k_established)
    const g = Math.max(0, Math.round(Number(placementGames)) || settings.elo_placement_games)
    setEloBusy(true); setEloErr(null)
    try {
      await setEloSettings({ elo_k_placement: p, elo_k_established: e, elo_placement_games: g })
      setDirty(false)
    } catch (err) { setEloErr((err as Error).message) }
    finally { setEloBusy(false) }
  }

  // Same local-draft/dirty/save pattern as the three K-factor fields above,
  // its own dirty flag/save button so saving one doesn't touch the other.
  const [botAfter, setBotAfter] = useState(String(settings.ranked_bot_after_seconds))
  const [botAfterBusy, setBotAfterBusy] = useState(false)
  const [botAfterErr, setBotAfterErr] = useState<string | null>(null)
  const [botAfterDirty, setBotAfterDirty] = useState(false)

  useEffect(() => {
    if (botAfterDirty) return
    setBotAfter(String(settings.ranked_bot_after_seconds))
  }, [settings.ranked_bot_after_seconds, botAfterDirty])

  async function saveBotAfter() {
    const n = Math.max(10, Math.min(600, Math.round(Number(botAfter)) || settings.ranked_bot_after_seconds))
    setBotAfterBusy(true); setBotAfterErr(null)
    try {
      await setRankedBotAfterSeconds(n)
      setBotAfterDirty(false)
    } catch (err) { setBotAfterErr((err as Error).message) }
    finally { setBotAfterBusy(false) }
  }

  // The live preview: two 1000-rated players, one four rating points above
  // the other -- close enough that expectedScore() alone isn't the whole
  // story, which is the point of showing it rather than just printing the
  // K-factor back. Uses whatever is in the (unsaved) draft fields, not the
  // committed settings, so moving a slider shows its effect before Save.
  const previewK = {
    placement: Math.max(1, Math.round(Number(placement)) || settings.elo_k_placement),
    established: Math.max(1, Math.round(Number(established)) || settings.elo_k_established),
    placementGames: Math.max(0, Math.round(Number(placementGames)) || settings.elo_placement_games),
  }
  const previewA = 1000
  const previewB = 1050
  const winAsPlacement = nextRating(previewA, previewB, true, 0, previewK)
  const winAsEstablished = nextRating(previewA, previewB, true, previewK.placementGames, previewK)
  const loseAsEstablished = nextRating(previewA, previewB, false, previewK.placementGames, previewK)
  const oddsA = Math.round(expectedScore(previewA, previewB) * 100)

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

      <hr className="matchend-divider" />

      <form
        className="admin-grid admin-nums"
        onSubmit={(e) => { e.preventDefault(); void saveElo() }}
      >
        <label><span>K while placing</span>
          <input
            type="number" value={placement}
            onChange={(e) => { setDirty(true); setPlacement(e.target.value) }}
          />
        </label>
        <label><span>K once established</span>
          <input
            type="number" value={established}
            onChange={(e) => { setDirty(true); setEstablished(e.target.value) }}
          />
        </label>
        <label><span>Placement games</span>
          <input
            type="number" value={placementGames}
            onChange={(e) => { setDirty(true); setPlacementGames(e.target.value) }}
          />
        </label>
        <button className="btn small" disabled={eloBusy || !dirty}>
          {eloBusy ? 'Saving…' : 'Save K-factor'}
        </button>
      </form>
      <p className="muted tiny">
        The Elo K-factor -- how many rating points change hands per game. A
        player under "placement games" finished draws the higher, more
        volatile K; everyone past it draws the lower one. Read fresh by
        finish_match() on every match that ends, so this takes effect on the
        very next one -- no redeploy.
      </p>
      {eloErr && <p className="error tiny">{eloErr}</p>}

      <p className="muted tiny">
        Preview: a 1000-rated player is about {oddsA}% to beat a 1050-rated
        one. Winning that game gains {winAsPlacement - previewA} points while
        placing, {winAsEstablished - previewA} once established; losing it
        while established costs {previewA - loseAsEstablished}.
      </p>

      <hr className="matchend-divider" />

      <form
        className="admin-grid admin-nums"
        onSubmit={(e) => { e.preventDefault(); void saveBotAfter() }}
      >
        <label><span>Ranked bot fallback (seconds)</span>
          <input
            type="number" min={10} max={600} value={botAfter}
            onChange={(e) => { setBotAfterDirty(true); setBotAfter(e.target.value) }}
          />
        </label>
        <button className="btn small" disabled={botAfterBusy || !botAfterDirty}>
          {botAfterBusy ? 'Saving…' : 'Save wait time'}
        </button>
      </form>
      <p className="muted tiny">
        How long ranked matchmaking waits without finding a real opponent
        before pairing you with a bot instead. That match still counts for
        real -- real rating, wins and losses -- just at a third of the usual
        Elo swing, against a bot given a random name, a random card portrait,
        and a rating near your own. Read fresh by ranked_tick() on every
        queue tick, so this takes effect immediately -- no redeploy. 10-600
        seconds.
      </p>
      {botAfterErr && <p className="error tiny">{botAfterErr}</p>}
    </div>
  )
}
