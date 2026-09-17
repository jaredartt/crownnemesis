import { useEffect, useMemo, useState } from 'react'
import {
  addRoyaleBot, deployRoyaleUnit, myRoyaleDeploy, removeRoyaleBot,
  setRoyaleReady, startRoyaleMatch,
} from '../lib/api'
import { BOT_LEVELS, type RoyaleMatchRow, type RoyalePlayerRow, type RoyaleUnit } from '../lib/types'
import { rkey, royaleZone } from '../lib/rulesRoyale'
import type { RoyaleTarget } from '../lib/rulesRoyale'
import { useT } from '../lib/i18n'
import { Avatar } from './Avatar'
import { nameColorStyle } from '../lib/nameColors'
import { RoyaleBoard } from './RoyaleBoard'

const SEAT_VAR = ['--you', '--foe', '--good', '--kw']
const NO_TARGETS = new Map<string, RoyaleTarget>()

/**
 * The room before the battle opens: seats filling up ('waiting'), then each
 * seat placing its five units inside its own quadrant ('deploying').
 *
 * These two used to be a single component, RoyaleLobby, that owned its own
 * full-page frame (`.center-stage` > `.rlobby`) -- entirely separate from
 * the `.match`/`.stage`/`.turnbar` frame the battle screen (RoyaleMatch.tsx)
 * uses. That is what the developer's own bug report ("bugged mini map",
 * "the two windows look fused", "no chat/log open on desktop", "the timer
 * bar isn't up there like 1v1") all trace back to: a deploying player's
 * board sat inside a container with no real height to size itself against
 * (`.rlobby` has none -- it is centered CONTENT, not a viewport frame), so
 * the `cqh`-based width formula RoyaleBoard.tsx borrows from 1v1's own
 * `.board` had nothing to measure and collapsed to whatever minimal size
 * its siblings forced -- the "tiny bugged minimap". And because it was a
 * screen of its own, it carried none of 1v1's persistent chrome: no
 * `.turnbar`, no always-open `.side` rails on desktop.
 *
 * The fix is not a new frame for THIS screen -- it is to stop giving it
 * one. `RoyaleWaitingRoom`/`RoyaleDeployRoom` now render only their OWN
 * content, exactly the way 1v1's Match.tsx renders its 'waiting' status
 * inline inside `<main className="center">` rather than as a separate
 * page -- RoyaleMatch.tsx is what supplies the shared `.match`/`.stage`/
 * `.turnbar`/side-rail frame for every status, deploying and waiting
 * included, the same frame the battle itself uses. That is also what
 * fixes the sizing bug on its own, with no board-specific patch needed:
 * `.center` sits inside `.match`'s real `height: 100dvh` flex column, so
 * the `.arena` these two now render their board inside (the SAME class
 * 1v1's board sizes itself against, not a bespoke `.rmatch-body` twin of
 * it) always has real space to measure.
 */
export function RoyaleWaitingRoom({
  match, players, mySeat,
}: {
  match: RoyaleMatchRow
  players: RoyalePlayerRow[]
  mySeat: number | null
}) {
  const t = useT()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [botLevel, setBotLevel] = useState(2)

  const isHost = mySeat === 0
  const hasEmptySeat = [0, 1, 2, 3].some((seat) => !players.some((p) => p.seat === seat))

  async function run(fn: () => Promise<unknown>) {
    setBusy(true); setErr(null)
    try { await fn() } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  return (
    <div className="waiting">
      <p className="muted">{t('royale.roomCode')}</p>
      <div className="bigcode">{match.code}</div>
      <button className="btn" onClick={() => navigator.clipboard?.writeText(match.code)}>
        {t('match.copyCodeBtn')}
      </button>

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
                  <span className="rseat-name" style={nameColorStyle(p.name_color)}>{p.username}</span>
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
        {!isHost && <span className="hint">{t('royale.waitForHost')}</span>}
      </div>
    </div>
  )
}

/**
 * The 'deploying' phase draws the full-size RoyaleBoard (not a cropped
 * one-quadrant grid), inside the SAME `.arena` 1v1's own board sizes
 * itself against, so a player can see the whole map and place themselves
 * in it exactly the way 1v1 shows the full board -- including the other
 * half -- while deploying. Fog of war is real, not just an omission: your
 * own placement comes from `myRoyaleDeploy()`, which (0054) is the only
 * thing that can ever read it before Ready. The other three quadrants
 * render genuinely empty here, the same way the 1v1 board's other half is
 * genuinely empty during deployment -- there is nothing this client is
 * allowed to know yet.
 */
export function RoyaleDeployRoom({
  match, players, mySeat,
}: {
  match: RoyaleMatchRow
  players: RoyalePlayerRow[]
  mySeat: number | null
}) {
  const t = useT()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const [pending, setPending] = useState<RoyaleUnit[] | null>(null)

  const me = players.find((p) => p.seat === mySeat)
  const zone = mySeat !== null ? royaleZone(mySeat) : null
  const units = pending ?? []
  const locked = Boolean(me?.ready)

  useEffect(() => {
    let alive = true
    myRoyaleDeploy(match.id).then((u) => { if (alive) setPending(u) })
    return () => { alive = false }
  }, [match.id])

  async function run(fn: () => Promise<unknown>) {
    setBusy(true); setErr(null)
    try { await fn() } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  async function onDeploy(id: string, x: number, y: number) {
    await run(async () => setPending(await deployRoyaleUnit(match.id, id, x, y)))
    setSelected(null)
  }

  // The board this draws is the real one -- board/obstacles come straight off
  // match.state, which is public (trees are terrain, not a secret) -- with
  // `units` replaced by your own pending five and nobody else's, which is
  // the whole fix. The other three quadrants are genuinely empty, exactly
  // the way the 1v1 board's other half is genuinely empty while deploying.
  const displayState = useMemo(
    () => ({ ...match.state, phase: 'deploy' as const, units }),
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
    <>
      <div
        className="arena"
        style={{ '--cols': match.state.board.w, '--rows': match.state.board.h } as React.CSSProperties}
      >
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
            if (!reachable.has(rkey(x, y))) { setSelected(null); return }
            onDeploy(selected, x, y)
          }}
          onTreeClick={() => {}}
        />
      </div>

      {err && <p className="error">{err}</p>}

      <ul className="rseats">
        {players.map((p) => (
          <li key={p.seat} className="rseat-row">
            <span
              className="rseat-dot"
              style={{ background: `var(${SEAT_VAR[p.seat]})` }}
              aria-hidden="true"
            />
            <Avatar slug={p.avatar} name={p.username} size={24} />
            <span className="rseat-name" style={nameColorStyle(p.name_color)}>{p.username}</span>
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
          onClick={() => run(() => setRoyaleReady(match.id))}
        >
          {t(locked ? 'royale.ready' : 'royale.setReady')}
        </button>
        <span className="hint">{t('royale.deployHint')}</span>
      </div>
      {players.length > 0 && players.every((p) => p.ready) && (
        <p className="muted tiny">{t('royale.startingNow')}</p>
      )}
    </>
  )
}
