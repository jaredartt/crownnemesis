import { useState } from 'react'
import {
  deployRoyaleUnit, leaveRoyaleMatch, setRoyaleReady, startRoyaleMatch,
} from '../lib/api'
import type { RoyaleMatchRow, RoyalePlayerRow } from '../lib/types'
import { royaleZone } from '../lib/rulesRoyale'
import { useT } from '../lib/i18n'
import { Avatar } from './Avatar'

const SEAT_VAR = ['--you', '--foe', '--good', '--kw']

/**
 * The room before the battle opens: seats filling up ('waiting'), then each
 * seat placing its five units inside its own quadrant ('deploying'). Kept
 * separate from RoyaleMatch/RoyaleBoard because the two phases share almost
 * nothing with the battle screen -- there is no turn, no target, no log
 * worth showing yet.
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

  const isHost = mySeat === 0
  const me = players.find((p) => p.seat === mySeat)
  const allReady = players.length > 0 && players.every((p) => p.ready)

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
                  </>
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

  // ---- deploying -----------------------------------------------------
  const zone = mySeat !== null ? royaleZone(mySeat) : null
  const pending = mySeat !== null ? (match.state.pendingUnits?.[String(mySeat)] ?? []) : []

  return (
    <div className="rlobby">
      <h2 className="rlobby-title">{t('royale.deployTitle')}</h2>
      {err && <p className="error">{err}</p>}
      {zone && mySeat !== null && (
        <div className="rdeploy">
          <div
            className="rdeploy-grid"
            style={{
              gridTemplateColumns: `repeat(${zone[1] - zone[0] + 1}, 1fr)`,
              gridTemplateRows: `repeat(${zone[3] - zone[2] + 1}, 1fr)`,
            }}
          >
            {Array.from({ length: (zone[3] - zone[2] + 1) * (zone[1] - zone[0] + 1) }, (_, i) => {
              const cols = zone[1] - zone[0] + 1
              const gx = zone[0] + (i % cols)
              const gy = zone[2] + Math.floor(i / cols)
              const there = pending.find((u) => u.x === gx && u.y === gy)
              return (
                <div
                  key={i}
                  className={`rdeploy-tile${there ? ' has-unit' : ''}`}
                  onClick={() => {
                    if (busy) return
                    if (there) { setSelected(there.id); return }
                    if (selected) {
                      run(() => deployRoyaleUnit(match.id, selected, gx, gy))
                      setSelected(null)
                    }
                  }}
                >
                  {there && (
                    <div className={`runit runit-mine${selected === there.id ? ' runit-selected' : ''}`}>
                      {there.royal && <span className="runit-crown" aria-hidden="true">♛</span>}
                      <span className="runit-name">{there.name.slice(0, 3)}</span>
                    </div>
                  )}
                </div>
              )
            })}
          </div>
          <p className="muted tiny">{t('royale.deployHint')}</p>
        </div>
      )}
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
            <span className={`pill ${p.ready ? 'active' : 'waiting'}`}>
              {t(p.ready ? 'royale.ready' : 'royale.notReady')}
            </span>
          </li>
        ))}
      </ul>
      <div className="actionbar">
        <button
          className="btn primary" disabled={busy || me?.ready}
          onClick={() => run(() => setRoyaleReady(match.id))}
        >
          {t(me?.ready ? 'royale.ready' : 'royale.setReady')}
        </button>
        <button className="btn ghost" onClick={leave}>{t('common.leave')}</button>
      </div>
      {allReady && <p className="muted tiny">{t('royale.startingNow')}</p>}
    </div>
  )
}
