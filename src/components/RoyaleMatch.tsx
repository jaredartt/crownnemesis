import { useEffect, useMemo, useRef, useState } from 'react'
import { BattleLog } from './BattleLog'
import { RoyaleBoard } from './RoyaleBoard'
import { RoyaleChat } from './RoyaleChat'
import { RoyaleLobby } from './RoyaleLobby'
import { useRoyaleMatch, useRoyaleMessages, useRoyalePlayers } from '../lib/useRoyaleMatch'
import { useServerClock } from '../lib/useMatch'
import {
  endRoyaleTurn, forceTimeoutRoyale, leaveRoyaleMatch, royaleBotStep, submitRoyaleAbility,
  submitRoyaleAttack, submitRoyaleDefend, submitRoyaleMove, submitRoyaleWait,
} from '../lib/api'
import { royaleCanAct, royaleReachable, royaleTargetsFor, type RoyaleTarget } from '../lib/rulesRoyale'
import type { Profile, RoyaleUnit } from '../lib/types'
import { nameColorStyle } from '../lib/nameColors'
import { useT } from '../lib/i18n'
import type { RoyaleBlow } from './RoyaleBoard'

const SEAT_VAR = ['--you', '--foe', '--good', '--kw']

/**
 * Battle Royale's top-level screen -- App.tsx's royale sibling of Match.tsx.
 * Deliberately rougher in two ways still: one shared board orientation for
 * every seat (no 4-way screen rotation -- a deliberate, requested property,
 * not a gap), and a plain action bar instead of Board.tsx's click-and-drag
 * choreography.
 *
 * Battle animation is real, just lighter than 1v1's: `cn_attack_royale`
 * writes `state.fx` exactly the way `cn_attack` does (it always has --
 * royale's own migration header even shows `cn_cine_ms` reading it), so the
 * data was there from day one; this file just never read it before. 1v1's
 * cinematic pauses the WHOLE board and zooms into a full-screen duel between
 * exactly two fighters -- right for a two-player match, wrong for a table
 * where two other seats may still want to look around while a third fight
 * resolves. So this plays the hit inline instead: the attacker's tile lunges,
 * the target flashes and shows a floating number, right on the live board,
 * with nothing paused and nothing hidden behind an overlay.
 */
export function RoyaleMatch({ matchId, profile, onLeave }: {
  matchId: string
  profile: Profile
  onLeave: () => void
}) {
  const t = useT()
  const { match, error, refresh } = useRoyaleMatch(matchId)
  const players = useRoyalePlayers(matchId)
  const messages = useRoyaleMessages(matchId)
  const clockOffset = useServerClock()

  const [selected, setSelected] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [rail, setRail] = useState<'chat' | 'log' | null>(null)
  const [now, setNow] = useState(Date.now())
  const firedFor = useRef<string>('')
  // The inline hit animation. Keyed by fx.seq so a fresh exchange always
  // restarts it even if the previous one is still fading out.
  const [blow, setBlow] = useState<RoyaleBlow | null>(null)
  const lastFxSeq = useRef<number | null>(null)

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])

  // RoyaleMatch is never remounted when the player leaves one match and
  // joins another (App.tsx renders it with no `key`, unlike 1v1's own
  // Match.tsx) -- so without this, a stale lastFxSeq from the match just
  // left could match the new match's very first fx.seq by coincidence
  // (most likely when seq numbering starts from 1 in every match) and
  // silently eat its first exchange's animation. Clearing both refs/state
  // whenever matchId changes keeps this component's fx tracking scoped to
  // whichever match is actually on screen.
  useEffect(() => {
    lastFxSeq.current = null
    setBlow(null)
  }, [matchId])

  // Fires once per NEW exchange, never on the first load of a match already
  // in flight -- lastFxSeq starts null and the first fx just primes it,
  // exactly the guard 1v1's own cinematic trigger uses for the same reason.
  useEffect(() => {
    const fx = match?.state?.fx
    if (!fx) return
    if (lastFxSeq.current === null) { lastFxSeq.current = fx.seq; return }
    if (fx.seq === lastFxSeq.current) return
    lastFxSeq.current = fx.seq
    setBlow({
      seq: fx.seq, atk: fx.atk, tgt: fx.tgt, dmg: fx.dmg, heal: fx.heal,
      crit: fx.crit, counter: fx.counter, killedTgt: fx.killedTgt, killedAtk: fx.killedAtk,
      hits: fx.hits,
    })
    const id = window.setTimeout(() => setBlow((b) => (b?.seq === fx.seq ? null : b)), 1000)
    return () => window.clearTimeout(id)
  }, [match?.state?.fx])

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

  // Same clock-enforcement idiom as Match.tsx (see that file's comment):
  // nobody runs a game server, so a client asks the database to expire the
  // turn once the deadline has passed. force_timeout_royale refuses unless
  // Postgres agrees the deadline has genuinely passed, so this is safe to
  // call from any client watching the match, including a spectator's.
  const onClock = match?.status === 'active'
  const remaining = useMemo(() => {
    if (!match?.turn_deadline || !onClock) return null
    return (new Date(match.turn_deadline).getTime() - (now + clockOffset)) / 1000
  }, [match?.turn_deadline, onClock, now, clockOffset])

  useEffect(() => {
    if (!match || !onClock || remaining === null) return
    const stamp = `${match.id}:${match.status}:${state?.turnNumber}`
    if (remaining < -2 && firedFor.current !== stamp) {
      firedFor.current = stamp
      forceTimeoutRoyale(match.id).then(refresh)
    }
  }, [remaining, match, onClock, state?.turnNumber, refresh])

  // 0052: whoever currently holds the turn, if that seat is a bot, gets
  // driven the same way Match.tsx drives the 1v1 bot -- one action per
  // call, on a delay, re-firing whenever match.updated_at changes so the
  // chain stops on its own the moment the turn moves on. Turns are still
  // strictly one-seat-at-a-time even with up to three bots at the table,
  // so there is never more than one bot seat to drive at once.
  const turnSeat = state?.turn ?? null
  const turnIsBot = Boolean(
    match?.status === 'active' && turnSeat !== null
    && players.find((p) => p.seat === turnSeat)?.bot != null,
  )
  useEffect(() => {
    if (!turnIsBot || !match || turnSeat === null) return
    const id = setTimeout(() => royaleBotStep(match.id, turnSeat).then(refresh), 650)
    return () => clearTimeout(id)
  }, [turnIsBot, match?.id, match?.updated_at, turnSeat, refresh])

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
  // The AFK-forfeit block in advance_turn_royale (0051) writes its own log
  // line immediately before the win it may cause, so "the last couple of
  // log lines mention a forfeit" is how a client tells "Y won because X
  // went AFK" from an ordinary elimination -- there is no separate
  // structured flag for it, by design (see the migration's own note).
  const recentLog = state?.log.slice(-2) ?? []
  const forfeited = recentLog.some((e) => e.text.includes('forfeited by inactivity'))
  const secsLeft = match.turn_deadline
    ? Math.max(0, Math.round((new Date(match.turn_deadline).getTime() - (now + clockOffset)) / 1000))
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
              <span style={nameColorStyle(p.name_color)}>{p.username}</span>
              {p.bot != null && <span className="rseat-bot-tag">{t('royale.botTag')}</span>}
            </li>
          ))}
        </ul>
        {secsLeft !== null && match.status === 'active' && (
          <span className="rmatch-clock">{secsLeft}s</span>
        )}
      </header>

      {match.status === 'finished' && (
        <div className="rmatch-banner">
          {match.draw
            ? t('royale.stalemateDraw')
            : winner
              ? (forfeited ? t('royale.forfeitWinnerIs', { name: winner.username }) : t('royale.winnerIs', { name: winner.username }))
              : t('royale.matchOver')}
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
            blow={blow}
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
