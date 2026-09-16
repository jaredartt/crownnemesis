import { useMemo, useState } from 'react'
import { BattleLog } from './BattleLog'
import { RoyaleBoard } from './RoyaleBoard'
import { RoyaleChat } from './RoyaleChat'
import { RoyaleLobby } from './RoyaleLobby'
import { useRoyaleMatch, useRoyaleMessages, useRoyalePlayers } from '../lib/useRoyaleMatch'
import { useServerClock } from '../lib/useMatch'
import {
  endRoyaleTurn, leaveRoyaleMatch, submitRoyaleAbility, submitRoyaleAttack, submitRoyaleDefend,
  submitRoyaleMove, submitRoyaleWait,
} from '../lib/api'
import { royaleCanAct, royaleReachable, royaleTargetsFor, type RoyaleTarget } from '../lib/rulesRoyale'
import type { Profile, RoyaleUnit } from '../lib/types'
import { useT } from '../lib/i18n'

const SEAT_VAR = ['--you', '--foe', '--good', '--kw']

/**
 * Battle Royale's top-level screen -- App.tsx's royale sibling of Match.tsx.
 * Deliberately rougher: one shared board orientation for every seat (no
 * 4-way screen rotation), no cinematic swing playback, a plain action bar
 * instead of Board.tsx's click-and-drag choreography. See the migration's
 * header and the project's stated priority order for why -- a full,
 * playable subset beats a beautiful, half-built one.
 */
export function RoyaleMatch({ matchId, profile, onLeave }: {
  matchId: string
  profile: Profile
  onLeave: () => void
}) {
  const t = useT()
  const { match, error } = useRoyaleMatch(matchId)
  const players = useRoyalePlayers(matchId)
  const messages = useRoyaleMessages(matchId)
  const clockOffset = useServerClock()

  const [selected, setSelected] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [rail, setRail] = useState<'chat' | 'log' | null>(null)

  const me = players.find((p) => p.user_id === profile.id)
  const mySeat = me?.seat ?? null
  const watching = mySeat === null || Boolean(me?.eliminated)

  function leave() {
    leaveRoyaleMatch(matchId)
    onLeave()
  }

  async function act(fn: () => Promise<unknown>) {
    setBusy(true); setErr(null)
    try { await fn() } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  const state = match?.state
  const myTurn = Boolean(state && mySeat !== null && state.turn === mySeat && match?.status === 'active')

  const selectedUnit = useMemo(
    () => state?.units.find((u) => u.id === selected) ?? null,
    [state, selected],
  )
  const reachable = useMemo(() => {
    if (!state || !selectedUnit || !myTurn || selectedUnit.moved) return new Set<string>()
    return royaleReachable(state, selectedUnit)
  }, [state, selectedUnit, myTurn])
  const targets = useMemo(() => {
    if (!state || !selectedUnit || !myTurn || selectedUnit.acted) return new Map<string, RoyaleTarget>()
    return royaleTargetsFor(state, selectedUnit)
  }, [state, selectedUnit, myTurn])

  function onUnitClick(u: RoyaleUnit) {
    if (!state || !myTurn) return
    if (selectedUnit && selectedUnit.id !== u.id && targets.has(u.id)) {
      act(() => submitRoyaleAttack(matchId, selectedUnit.id, u.id))
      return
    }
    if (u.owner === mySeat && royaleCanAct(state, u)) {
      setSelected((s) => (s === u.id ? null : u.id))
      return
    }
    setSelected(null)
  }
  function onTileClick(x: number, y: number) {
    if (!selectedUnit || !myTurn) return
    act(() => submitRoyaleMove(matchId, selectedUnit.id, x, y))
  }
  function onTreeClick(id: string) {
    if (!selectedUnit || !myTurn) return
    act(() => submitRoyaleAttack(matchId, selectedUnit.id, id))
  }

  if (error) return <div className="center-stage"><p className="error">{error}</p></div>
  if (!match) return <div className="center-stage"><p className="muted">{t('app.loading')}</p></div>

  if (match.status === 'waiting' || match.status === 'deploying') {
    return (
      <div className="center-stage">
        <RoyaleLobby match={match} players={players} mySeat={mySeat} onLeave={onLeave} />
      </div>
    )
  }

  const winner = match.status === 'finished'
    ? players.find((p) => p.seat === match.winner_seat)
    : null
  const secsLeft = match.turn_deadline
    ? Math.max(0, Math.round((new Date(match.turn_deadline).getTime() - (Date.now() + clockOffset)) / 1000))
    : null

  return (
    <div className="rmatch">
      <header className="rmatch-head">
        <button className="btn ghost small" onClick={leave}>{t('common.leave')}</button>
        <ul className="rmatch-seats">
          {players.map((p) => (
            <li
              key={p.seat}
              className={`rmatch-seat${p.eliminated ? ' is-out' : ''}${state?.turn === p.seat ? ' is-turn' : ''}`}
            >
              <span className="rseat-dot" style={{ background: `var(${SEAT_VAR[p.seat]})` }} aria-hidden="true" />
              {p.username}
            </li>
          ))}
        </ul>
        {secsLeft !== null && match.status === 'active' && (
          <span className="rmatch-clock">{secsLeft}s</span>
        )}
      </header>

      {match.status === 'finished' && (
        <div className="rmatch-banner">
          {winner ? t('royale.winnerIs', { name: winner.username }) : t('royale.matchOver')}
        </div>
      )}

      {err && <p className="error rmatch-err">{err}</p>}

      <div className="rmatch-body">
        {state && (
          <RoyaleBoard
            state={state}
            mySeat={mySeat}
            selected={selected}
            reachable={reachable}
            targets={targets}
            watching={watching || match.status !== 'active'}
            onUnitClick={onUnitClick}
            onTileClick={onTileClick}
            onTreeClick={onTreeClick}
          />
        )}
      </div>

      {myTurn && (
        <div className="actionbar rmatch-actions">
          {selectedUnit && !selectedUnit.acted && selectedUnit.abilityKind
            && selectedUnit.abilityKind !== 'mist' && selectedUnit.abilityKind !== 'summon' && (
            <button
              className="btn small" disabled={busy}
              onClick={() => act(() => submitRoyaleAbility(matchId, selectedUnit.id, null))}
            >
              {t('royale.useAbility')}
            </button>
          )}
          {selectedUnit && !selectedUnit.acted && (
            <button
              className="btn small" disabled={busy}
              onClick={() => act(() => submitRoyaleDefend(matchId, selectedUnit.id))}
            >
              {t('royale.defend')}
            </button>
          )}
          {selectedUnit && (
            <button
              className="btn small ghost" disabled={busy}
              onClick={() => act(() => submitRoyaleWait(matchId))}
            >
              {t('royale.wait')}
            </button>
          )}
          <button
            className="btn small primary" disabled={busy}
            onClick={() => act(() => endRoyaleTurn(matchId))}
          >
            {t('royale.endTurn')}
          </button>
        </div>
      )}

      <div className="rmatch-rails">
        <button className="btn tiny ghost" onClick={() => setRail(rail === 'log' ? null : 'log')}>
          {t('log.title')}
        </button>
        <button className="btn tiny ghost" onClick={() => setRail(rail === 'chat' ? null : 'chat')}>
          {t('chat.title')}
        </button>
      </div>
      {rail === 'log' && state && <BattleLog log={state.log} open />}
      {rail === 'chat' && (
        <RoyaleChat matchId={matchId} profile={profile} messages={messages} open />
      )}
    </div>
  )
}
