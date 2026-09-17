import { useEffect, useMemo, useState } from 'react'
import {
  addRoyaleBot, deployRoyaleUnit, leaveRoyaleMatch, myRoyaleDeploy, removeRoyaleBot,
  setRoyaleReady, startRoyaleMatch,
} from '../lib/api'
import { BOT_LEVELS, type RoyaleMatchRow, type RoyalePlayerRow, type RoyaleUnit } from '../lib/types'
import { rkey, royaleZone } from '../lib/rulesRoyale'
import type { RoyaleTarget } from '../lib/rulesRoyale'
import { useT } from '../lib/i18n'
import { Avatar } from './Avatar'
import { RoyaleBoard } from './RoyaleBoard'

const SEAT_VAR = ['--you', '--foe', '--good', '--kw']
const NO_TARGETS = new Map<string, RoyaleTarget>()

/**
 * The room before the battle opens: seats filling up ('waiting'), then each
 * seat placing its five units inside its own quadrant ('deploying'). Kept
 * separate from RoyaleMatch/RoyaleBoard because the two phases share almost
 * nothing with the battle screen -- there is no turn, no target, no log
 * worth showing yet.
 *
 * The 'deploying' phase draws the SAME full-size RoyaleBoard the battle uses
 * (not a cropped one-quadrant grid) so a player can see the whole map and
 * place themselves in it, exactly the way Match.tsx shows the full 1v1
 * board -- including the other half -- while deploying. Fog of war is real,
 * not just an omission: your own placement comes from `myRoyaleDeploy()`,
 * which (0054_royale_deploy_fog.sql) is the only thing that can ever read
 * it before Ready. The other three quadrants render genuinely empty here,
 * the same way the 1v1 board's other half is genuinely empty during
 * deployment -- there is nothing this client is allowed to know yet.
 */
export function RoyaleLobby({
  match, players, mySeat, onLeave,
}: {
  match: RoyaleMatchRow
  players: RoyalePlayerRow[]
  mySeat: number | null
  onLeave: () => void
}) {
  const t = useT()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  // Your own five, fetched fresh whenever this phase opens -- never read off
  // match.state, which no longer carries anyone's placement (see the module
  // comment above).
  const [pending, setPending] = useState<RoyaleUnit[] | null>(null)
  // The difficulty the host's next "Add bot" click uses -- one shared
  // picker above the seat list rather than one per empty seat, since a
  // friends' room rarely needs each bot tuned separately (see
  // create_royale_bot_match's own Vs Bots picker for the same call).
  const [botLevel, setBotLevel] = useState(2)

  const isHost = mySeat === 0
  const me = players.find((p) => p.seat === mySeat)
  const hasEmptySeat = [0, 1, 2, 3].some((seat) => !players.some((p) => p.seat === seat))

  useEffect(() => {
    if (match.status !== 'deploying') { setPending(null); return }
    let alive = true
    myRoyaleDeploy(match.id).then((u) => { if (alive) setPending(u) })
    return () => { alive = false }
  }, [match.id, match.status])

  async function run(fn: () => Promise<unknown>) {
    setBusy(true); setErr(null)
    try { await fn() } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  function leave() {
    leaveRoyaleMatch(match.id)
    onLeave()
  }

  if (match.status === 'waiting') {
    return (
      <div className="rlobby">
        <h2 className="rlobby-title">{t('royale.waitingTitle')}</h2>
        <p className="rlobby-code">
          {t('royale.roomCode')}: <span className="code">{match.code}</span>
        </p>
        {isHost && hasEmptySeat && (
          <div className="rbotpicker">
            <span className="muted tiny">{t('royale.botDifficulty')}</span>
            <div className="seg" role="radiogroup" aria-label={t('royale.botDifficulty')}>
              {BOT_LEVELS.map((b) => (
                <button
                  key={b.level}
                  type="button"
                  role="radio"
                  aria-checked={botLevel === b.level}
                  className={botLevel === b.level ? 'is-on' : ''}
                  onClick={() => setBotLevel(b.level)}
                >
                  {t(`bot.${b.key}`)}
                </button>
              ))}
            </div>
          </div>
        )}
        <ul className="rseats">
          {[0, 1, 2, 3].map((seat) => {
            const p = players.find((pp) => pp.seat === seat)
            return (
              <li key={seat} className="rseat-row">
                <span
                  className="rseat-dot"
                  style={{ background: `var(${SEAT_VAR[seat]})` }}
                  aria-hidden="true"
                />
                {p ? (
                  <>
                    <Avatar slug={p.avatar} name={p.username} size={28} />
                    <span className="rseat-name">{p.username}</span>
                    {p.bot != null && isHost && (
                      <button
                        className="btn tiny ghost" disabled={busy}
                        onClick={() => run(() => removeRoyaleBot(match.id, seat))}
                      >
                        {t('common.remove')}
                      </button>
                    )}
                  </>
                ) : isHost ? (
                  <button
                    className="btn tiny" disabled={busy}
                    onClick={() => run(() => addRoyaleBot(match.id, seat, botLevel))}
                  >
                    {t('royale.addBot')}
                  </button>
                ) : (
                  <span className="muted">{t('royale.emptySeat')}</span>
                )}
              </li>
            )
          })}
        </ul>
        {err && <p className="error">{err}</p>}
        <div className="actionbar">
          {isHost && (
            <button
              className="btn primary" disabled={busy || players.length < 2}
              onClick={() => run(() => startRoyaleMatch(match.id))}
            >
              {t('royale.startMatch')}
            </button>
          )}
          {!isHost && <p className="muted tiny">{t('royale.waitForHost')}</p>}
          <button className="btn ghost" onClick={leave}>{t('common.leave')}</button>
        </div>
      </div>
    )
  }

  // ---- deploying -------------------------------------------------------
  return (
    <RoyaleDeploy
      match={match}
      players={players}
      mySeat={mySeat}
      pending={pending}
      selected={selected}
      setSelected={setSelected}
      busy={busy}
      err={err}
      me={me}
      onDeploy={async (id, x, y) => {
        await run(async () => setPending(await deployRoyaleUnit(match.id, id, x, y)))
        setSelected(null)
      }}
      onReady={() => run(() => setRoyaleReady(match.id))}
      onLeave={leave}
    />
  )
}

function RoyaleDeploy({
  match, players, mySeat, pending, selected, setSelected, busy, err, me, onDeploy, onReady, onLeave,
}: {
  match: RoyaleMatchRow
  players: RoyalePlayerRow[]
  mySeat: number | null
  pending: RoyaleUnit[] | null
  selected: string | null
  setSelected: (id: string | null) => void
  busy: boolean
  err: string | null
  me: RoyalePlayerRow | undefined
  onDeploy: (id: string, x: number, y: number) => void
  onReady: () => void
  onLeave: () => void
}) {
  const t = useT()
  const zone = mySeat !== null ? royaleZone(mySeat) : null
  const units = pending ?? []
  const locked = Boolean(me?.ready)

  // The board this draws is the real one -- board/obstacles come straight off
  // match.state, which is public (trees are terrain, not a secret) -- with
  // `units` replaced by your own pending five and nobody else's, which is
  // the whole fix. The other three quadrants are genuinely empty, exactly
  // the way the 1v1 board's other half is genuinely empty while deploying.
  const displayState = useMemo(
    () => ({ ...match.state, units }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [match.state.board, match.state.obstacles, units],
  )

  // Where a selected unit may move: any empty, tree-free tile in your own
  // zone. Not pathfinding -- deployment has no movement cost -- just "is it
  // inside my corner and unoccupied".
  const reachable = useMemo(() => {
    const s = new Set<string>()
    if (!zone || !selected || locked) return s
    const occupied = new Set(units.map((u) => rkey(u.x, u.y)))
    for (let y = zone[2]; y <= zone[3]; y++) {
      for (let x = zone[0]; x <= zone[1]; x++) {
        const k = rkey(x, y)
        if (!occupied.has(k)) s.add(k)
      }
    }
    return s
  }, [zone, selected, locked, units])

  return (
    <div className="rlobby rlobby-deploy">
      <h2 className="rlobby-title">{t('royale.deployTitle')}</h2>
      {err && <p className="error">{err}</p>}
      <div className="rmatch-body">
        <RoyaleBoard
          state={displayState}
          mySeat={mySeat}
          selected={selected}
          reachable={reachable}
          targets={NO_TARGETS}
          watching={locked}
          onUnitClick={(u) => {
            if (locked || u.owner !== mySeat) return
            setSelected(selected === u.id ? null : u.id)
          }}
          onTileClick={(x, y) => {
            if (!selected || locked) return
            onDeploy(selected, x, y)
          }}
          onTreeClick={() => {}}
        />
      </div>
      <p className="muted tiny">{t('royale.deployHint')}</p>
      <ul className="rseats">
        {players.map((p) => (
          <li key={p.seat} className="rseat-row">
            <span
              className="rseat-dot"
              style={{ background: `var(${SEAT_VAR[p.seat]})` }}
              aria-hidden="true"
            />
            <Avatar slug={p.avatar} name={p.username} size={24} />
            <span className="rseat-name">{p.username}</span>
            {p.bot != null && <span className="rseat-bot-tag">{t('royale.botTag')}</span>}
            <span className={`pill ${p.ready ? 'active' : 'waiting'}`}>
              {t(p.ready ? 'royale.ready' : 'royale.notReady')}
            </span>
          </li>
        ))}
      </ul>
      <div className="actionbar">
        <button
          className="btn primary" disabled={busy || locked}
          onClick={onReady}
        >
          {t(locked ? 'royale.ready' : 'royale.setReady')}
        </button>
        <button className="btn ghost" onClick={onLeave}>{t('common.leave')}</button>
      </div>
      {players.length > 0 && players.every((p) => p.ready) && (
        <p className="muted tiny">{t('royale.startingNow')}</p>
      )}
    </div>
  )
}
