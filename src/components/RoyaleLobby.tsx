import { useState } from 'react'
import {
  addRoyaleBot, deployRoyaleUnit, leaveRoyaleMatch, removeRoyaleBot, setRoyaleReady,
  startRoyaleMatch,
} from '../lib/api'
import { BOT_LEVELS, type RoyaleMatchRow, type RoyalePlayerRow } from '../lib/types'
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
  // The difficulty the host's next "Add bot" click uses -- one shared
  // picker above the seat list rather than one per empty seat, since a
  // friends' room rarely needs each bot tuned separately (see
  // create_royale_bot_match's own Vs Bots picker for the same call).
  const [botLevel, setBotLevel] = useState(2)

  const isHost = mySeat === 0
  const me = players.find((p) => p.seat === mySeat)
  const allReady = players.length > 0 && players.every((p) => p.ready)
  const hasEmptySeat = [0, 1, 2, 3].some((seat) => !players.some((p) => p.seat === seat))

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
            {p.bot != null && <span className="rseat-bot-tag">{t('royale.botTag')}</span>}
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
