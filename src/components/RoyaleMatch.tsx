import { useEffect, useMemo, useRef, useState } from 'react'
import { BattleLog } from './BattleLog'
import { RoyaleBoard, type RoyaleMenu } from './RoyaleBoard'
import { RoyaleChat } from './RoyaleChat'
import { RoyaleDeployRoom, RoyaleWaitingRoom } from './RoyaleLobby'
import { useRoyaleMatch, useRoyaleMessages, useRoyalePlayers } from '../lib/useRoyaleMatch'
import { useServerClock } from '../lib/useMatch'
import {
  endRoyaleTurn, forceTimeoutRoyale, leaveRoyaleMatch, royaleBotStep, submitRoyaleAbility,
  submitRoyaleAttack, submitRoyaleDefend, submitRoyaleMove, submitRoyaleWait,
} from '../lib/api'
import {
  rkey, royaleActsCap, royaleCanAct, royaleReachable, royaleTargetsFor, type RoyaleTarget,
} from '../lib/rulesRoyale'
import { DEPLOY_SECONDS, TURN_SECONDS, type Profile, type RoyaleUnit } from '../lib/types'
import { nameColorStyle } from '../lib/nameColors'
import { useT } from '../lib/i18n'
import { Modal } from './Modal'
import { TurnBand } from './TurnBand'
import { RoyaleVsIntro } from './VsIntro'
import type { RoyaleBlow } from './RoyaleBoard'

const SEAT_VAR = ['--you', '--foe', '--good', '--kw']
type Mode = 'menu' | 'move' | 'attack' | null

// How often a missed bot attempt gets retried -- see the effect below.
const BOT_RETRY_MS = 2000
// Jared: royale gets the same arrival sequence 1v1's Match.tsx now opens
// every match with -- see that file's own GET_READY_MS for the reasoning.
const GET_READY_MS = 1000

/**
 * Battle Royale's top-level screen -- App.tsx's royale sibling of Match.tsx,
 * and since this pass built on the SAME `.match`/`.matchbar`/`.turnbar`/
 * `.stage` frame 1v1 uses rather than a parallel `.rmatch*` set of its own.
 * That is deliberate, not cosmetic: a future change to 1v1's header, clock
 * bar or side-rail behaviour now reaches royale for free, which is exactly
 * what the developer asked for ("if something gets updated in 1v1, 4-player
 * mode should have it instantly too").
 *
 * The frame is rendered ONCE, for every status -- waiting, deploying,
 * active, finished -- the same way Match.tsx renders `.match`/`.stage` once
 * and switches only what `<main className="center">` shows. Splitting the
 * lobby into its own separate full-page component (the old shape) is what
 * caused the reported "bugged mini map": that page had no real viewport
 * height to size a board against. Nesting everything in the one frame fixes
 * that at the root, for every phase, rather than patching the board's own
 * sizing formula.
 *
 * Battle animation is real, just lighter than 1v1's: `cn_attack_royale`
 * writes `state.fx` exactly the way `cn_attack` does, so the data was there
 * from day one; this file just reads it. 1v1's cinematic pauses the WHOLE
 * board and zooms into a full-screen duel between exactly two fighters --
 * right for a two-player match, wrong for a table where two other seats may
 * still want to look around while a third fight resolves. So this plays the
 * hit inline instead: the attacker's tile lunges, the target flashes and
 * shows a floating number, right on the live board, with nothing paused and
 * nothing hidden behind an overlay.
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
  const [mode, setMode] = useState<Mode>(null)
  // FRIENDLY FIRE CONFIRMATION -- same reasoning as Board.tsx's own
  // confirmAttackId: Royale's own owner/ally rule (rulesRoyale.ts's
  // royaleTargetsFor) means a player's OWN units can stand next to each
  // other same as any 1v1 ally pair, so the same misclick risk applies
  // here. Holds the (attacker, target) pair until answered; a Yes fires
  // the exact submitRoyaleAttack call onUnitClick would have fired anyway.
  const [confirmAttack, setConfirmAttack] = useState<{ unit: string; target: string } | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [rail, setRail] = useState<'chat' | 'log' | null>(null)
  const [now, setNow] = useState(Date.now())
  const firedFor = useRef<string>('')
  // The inline hit animation. Keyed by fx.seq so a fresh exchange always
  // restarts it even if the previous one is still fading out.
  const [blow, setBlow] = useState<RoyaleBlow | null>(null)
  const lastFxSeq = useRef<number | null>(null)
  // The turn-announcement band -- same component, same rules as 1v1's
  // Match.tsx (see TurnBand.tsx and that file's own comment on the
  // detector effect below, which this one is a direct twin of). No VS
  // intro to wait for here -- royale never shows one -- so this is simply
  // gated on the match being active.
  const [turnBand, setTurnBand] = useState<
    { sig: string; name: string; avatar: string | null; color: string | null } | null
  >(null)
  const turnBandSeen = useRef<string | null>(null)
  // "Get ready!" then the VS screen -- once per match, the instant it
  // BECOMES one. Same shape as 1v1's own pair in Match.tsx: `opened`
  // guards against re-firing within one mount, `introWanted` is what the
  // turn-band detector and the bot-driver below both hold off for, and
  // gating on match.status === 'deploying' rather than turnNumber means a
  // reconnect mid-deployment gets the same intro a first arrival would --
  // the one case this can still repeat, same as 1v1's.
  const [showGetReady, setShowGetReady] = useState(false)
  const [showVsIntro, setShowVsIntro] = useState(false)
  const introWanted = useRef(false)
  const opened = useRef<string | null>(null)

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    if (!matchId || match?.status !== 'deploying') return
    if (opened.current === matchId) return
    opened.current = matchId
    introWanted.current = true
    setShowGetReady(true)
    const id = setTimeout(() => { setShowGetReady(false); setShowVsIntro(true) }, GET_READY_MS)
    return () => clearTimeout(id)
  }, [matchId, match?.status])

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
  const deploying = match?.status === 'deploying'
  const myTurn = Boolean(state && mySeat !== null && state.turn === mySeat && match?.status === 'active')

  // Clear the selection/menu whenever the turn flips -- same rule 1v1's
  // Match.tsx uses (`useEffect(() => setSelected(null), [state?.turn, ...])`.
  useEffect(() => {
    setSelected(null); setMode(null); setConfirmAttack(null)
  }, [state?.turn, state?.turnNumber])

  // Fires once per new `turn:turnNumber` pair this component has seen,
  // same "ref outside render, state drives the UI" split as 1v1's own
  // detector -- including this component's very first render into a match
  // already under way, since `turnBandSeen` starts null. `players` may not
  // have loaded yet on that very first tick (it's its own separate realtime
  // hook); the effect re-runs once it does because `players` is in its
  // dependency list, so the band still lands, just a beat later than usual --
  // better than silently skipping the announcement because of a load-order
  // race between two hooks that were never guaranteed to resolve together.
  useEffect(() => {
    if (!match || match.status !== 'active' || !state || introWanted.current) return
    const sig = `${state.turn}:${state.turnNumber}`
    if (turnBandSeen.current === sig) return
    const p = players.find((pl) => pl.seat === state.turn)
    if (!p) return // players hasn't loaded yet -- try again once it has
    turnBandSeen.current = sig
    setTurnBand({ sig, name: p.username, avatar: p.avatar, color: p.name_color ?? null })
  }, [match, state?.turn, state?.turnNumber, players, showVsIntro])

  // The turn's budget. 0061 fixed royale's cap at one activation, always --
  // see royaleActsCap()'s own comment on why that is a named export rather
  // than a literal scattered at every call site.
  const actsCapNow = royaleActsCap()
  const actsSpent = Math.min(actsCapNow, state?.acts ?? 0)

  const onClock = match?.status === 'active' || deploying
  const clockLength = deploying ? DEPLOY_SECONDS : TURN_SECONDS
  const remaining = useMemo(() => {
    if (!match?.turn_deadline || !onClock) return null
    return (new Date(match.turn_deadline).getTime() - (now + clockOffset)) / 1000
  }, [match?.turn_deadline, onClock, now, clockOffset])

  // Same clock-enforcement idiom as Match.tsx (see that file's own
  // comment): nobody runs a game server, so a client asks the database to
  // expire the turn once the deadline has passed. force_timeout_royale
  // refuses unless Postgres agrees the deadline has genuinely passed, so
  // this is safe to call from any client watching the match, including a
  // spectator's.
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
  // chain stops on its own the moment the turn moves on.
  const turnSeat = state?.turn ?? null
  // Same rule as 1v1's Match.tsx: don't let a bot act until its own turn
  // band has fully cleared (`!turnBand`), rather than racing a fixed delay
  // against however long the band happens to still be up.
  const turnIsBot = Boolean(
    match?.status === 'active' && turnSeat !== null
    && players.find((p) => p.seat === turnSeat)?.bot != null && !turnBand
    // Same reasoning as 1v1's own botTurn: turnBand stays null for the
    // WHOLE time Get Ready/the VS screen are up (the detector above holds
    // off on creating it until introWanted.current clears), so `!turnBand`
    // alone would let a bot's opening move fire underneath the overlay.
    && !showGetReady && !showVsIntro,
  )
  //
  // Jared: bots "let all the seconds run out" sometimes -- traced to this
  // being a SINGLE scheduled attempt. With up to four seats, whether a bot's
  // move actually happens on time depends on some human's tab being open,
  // focused, and unthrottled at that exact moment -- a backgrounded tab
  // (browsers throttle a hidden tab's timers), a tab nobody has open because
  // everyone still at the table is watching someone else's fight, or one
  // dropped RPC round-trip is enough to burn the only attempt this used to
  // get, and there is no `updated_at` change coming to reschedule it because
  // the bot never acted -- so it just sits until `advance_turn_royale`'s own
  // timeout path forces the turn along WITHOUT the bot having played (see
  // that function's 0051 AFK-forfeit block, which deliberately never blames
  // a bot seat for this -- it assumes the client always lands the call before
  // the clock does, which is exactly the assumption that was failing).
  // Retried every BOT_RETRY_MS instead of scheduled once, the same
  // "realtime is the fast path, the poll underneath is the safety net" idiom
  // useRoyaleMatch already uses for the match row itself. Retrying is free:
  // royale_bot_step reads the live turn under its own row lock and no-ops
  // the instant it is not this seat's turn any more, so a redundant call
  // once the turn has already moved on (or another of the table's tabs beat
  // this one to it) costs nothing.
  useEffect(() => {
    if (!turnIsBot || !match || turnSeat === null) return
    let cancelled = false
    // Same fix as 1v1's Match.tsx (see its own comment): a slow-but-fine
    // `royaleBotStep` call must not let this retry fire a SECOND one on top
    // of it, or two actions can land close enough together that this
    // component's board never renders the state in between -- which is
    // exactly how a fight scene gets skipped or a move stops animating.
    const inFlight = { current: false }
    const attempt = () => {
      if (cancelled || inFlight.current) return
      inFlight.current = true
      royaleBotStep(match.id, turnSeat).then(refresh).finally(() => { inFlight.current = false })
    }
    const first = setTimeout(attempt, 650)
    const retry = setInterval(attempt, BOT_RETRY_MS)
    return () => { cancelled = true; clearTimeout(first); clearInterval(retry) }
  }, [turnIsBot, match?.id, match?.updated_at, turnSeat, refresh])

  const selectedUnit = useMemo(
    () => state?.units.find((u) => u.id === selected) ?? null,
    [state, selected],
  )
  const mine = Boolean(selectedUnit && mySeat !== null && selectedUnit.owner === mySeat)

  // Both computed unconditionally -- same reason Board.tsx computes
  // canMove/canStrike before any menu is open: the menu needs to know
  // whether Move and Attack are worth offering before you pick one.
  const canMove = Boolean(
    selectedUnit && mine && myTurn && !selectedUnit.moved && royaleCanAct(state!, selectedUnit),
  )
  const canAttack = Boolean(
    selectedUnit && mine && myTurn && !selectedUnit.acted && royaleCanAct(state!, selectedUnit),
  )
  const hasAbility = Boolean(
    selectedUnit?.abilityKind && selectedUnit.abilityKind !== 'mist' && selectedUnit.abilityKind !== 'summon',
  )
  const canAbility = canAttack && hasAbility
  const showWait = Boolean(selectedUnit && (state?.active ?? null) === selectedUnit.id)

  // Only lit while the matching aim step is actually open -- a menu that is
  // merely offered draws nothing extra, exactly like Board.tsx's own
  // showTiles/showTargets gate.
  const reachable = useMemo(() => {
    if (!state || !selectedUnit || mode !== 'move') return new Set<string>()
    return royaleReachable(state, selectedUnit)
  }, [state, selectedUnit, mode])
  const targets = useMemo(() => {
    if (!state || !selectedUnit || mode !== 'attack') return new Map<string, RoyaleTarget>()
    return royaleTargetsFor(state, selectedUnit)
  }, [state, selectedUnit, mode])

  function onUnitClick(u: RoyaleUnit) {
    // `busy` (see `act` above) covers the same round-trip gap 1v1's Match.tsx
    // closes with its own `busy` + `<Board locked>` -- without it, a second
    // click here can fire before the first action's response has landed,
    // which is exactly how a fight scene gets skipped or a move teleports
    // instead of animating (see Match.tsx's `guard` comment for the full
    // root-cause writeup; same mechanism, same fix, this component's board).
    if (!state || !myTurn || turnBand || busy) return
    if (mode === 'attack' && selectedUnit && u.id !== selectedUnit.id && targets.has(u.id)) {
      // FRIENDLY FIRE CONFIRMATION -- see confirmAttack's own comment above.
      if (targets.get(u.id)?.kind === 'ally') {
        setConfirmAttack({ unit: selectedUnit.id, target: u.id })
        return
      }
      act(() => submitRoyaleAttack(matchId, selectedUnit.id, u.id))
      setMode(null)
      return
    }
    if (u.id === selected && mode) { setMode(null); return }
    if (u.owner === mySeat && royaleCanAct(state, u)) {
      setSelected(u.id)
      setMode('menu')
      return
    }
    setSelected(null)
    setMode(null)
  }
  function onTileClick(x: number, y: number) {
    if (!selectedUnit || !myTurn || turnBand || busy) return
    if (mode === 'move' && reachable.has(rkey(x, y))) {
      act(() => submitRoyaleMove(matchId, selectedUnit.id, x, y))
      setMode('menu')
      return
    }
    setSelected(null)
    setMode(null)
  }
  function onTreeClick(id: string) {
    // RoyaleBoard only calls this when the tree is a live target (its own
    // `targets` map, built from the same `targets` this component computed)
    // -- see that file's onClick for the "else cancel" half of this.
    if (!selectedUnit || !myTurn || turnBand || busy) return
    act(() => submitRoyaleAttack(matchId, selectedUnit.id, id))
    setMode(null)
  }

  const menu: RoyaleMenu | null = useMemo(() => {
    if (mode !== 'menu' || !selectedUnit || !mine || !myTurn) return null
    return {
      unit: selectedUnit,
      canMove,
      canAttack,
      canAbility,
      hasAbility,
      showWait,
      onOpenMove: () => setMode('move'),
      onOpenAttack: () => setMode('attack'),
      onAbility: () => { act(() => submitRoyaleAbility(matchId, selectedUnit.id, null)); setMode(null) },
      onDefend: () => { act(() => submitRoyaleDefend(matchId, selectedUnit.id)); setMode(null) },
      onWait: () => { act(() => submitRoyaleWait(matchId)); setMode(null) },
      onCancel: () => { setSelected(null); setMode(null) },
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, selectedUnit, mine, myTurn, canMove, canAttack, canAbility, hasAbility, showWait])

  if (error) return <div className="center-stage"><p className="error">{error}</p></div>
  if (!match) return <div className="center-stage"><p className="muted">{t('app.loading')}</p></div>

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
  const pct = remaining === null ? 0 : Math.max(0, Math.min(1, remaining / clockLength))
  const urgent = remaining !== null && remaining <= 8

  return (
    <>
    <div className="match">
      <header className="matchbar">
        <button className="linkbtn" onClick={leave}>{t('common.leave')}</button>

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

        <div className="matchbar-right">
          <button
            className="roomcode"
            title={t('match.copyCode')}
            onClick={() => navigator.clipboard?.writeText(match.code)}
          >
            {match.code}
          </button>
          {watching && <span className="pill spectating">{t('match.watching')}</span>}
        </div>
      </header>

      {showGetReady && (
        <div className="getready" role="status">
          <p>{t('match.getReady')}</p>
        </div>
      )}

      {showVsIntro && (
        <RoyaleVsIntro
          players={players}
          onDone={() => { introWanted.current = false; setShowVsIntro(false) }}
        />
      )}

      {turnBand && (
        <TurnBand
          key={turnBand.sig}
          name={turnBand.name}
          avatarSlug={turnBand.avatar}
          color={turnBand.color}
          onDone={() => setTurnBand((b) => (b?.sig === turnBand.sig ? null : b))}
        />
      )}

      {onClock && (
        <div className={`turnbar ${urgent ? 'urgent' : ''}`}>
          <div className="timerbar">
            <div className="timerfill" style={{ width: `${pct * 100}%` }} />
          </div>
          <div className="timertext">
            {deploying
              ? t(me?.ready ? 'royale.waitingForThem' : 'royale.placeUnits')
              : myTurn
                ? t('match.yourTurn')
                : mySeat !== null
                  ? t('match.opponentThinking')
                  : t('royale.watchingTurn')}
            {' · '}
            {Math.max(0, Math.ceil(remaining ?? 0))}s
          </div>
          {match.status === 'active' && !match.draw && (
            <div
              className="goes"
              role="img"
              aria-label={t('match.goesLabel', {
                left: actsCapNow - actsSpent, cap: actsCapNow, word: t('match.go'),
              })}
              title={t('match.goesLeft', { left: actsCapNow - actsSpent, cap: actsCapNow })}
            >
              {Array.from({ length: actsCapNow }, (_, i) => (
                <span key={i} className={`go${i < actsSpent ? ' is-used' : ''}`} />
              ))}
            </div>
          )}
        </div>
      )}

      {err && <div className="toast">{err}</div>}

      <div className="stage">
        <RoyaleChat matchId={matchId} profile={profile} messages={messages} open={rail === 'chat'} />

        <main className="center">
          {match.status === 'waiting' && (
            <RoyaleWaitingRoom match={match} players={players} mySeat={mySeat} />
          )}

          {match.status === 'deploying' && (
            <RoyaleDeployRoom match={match} players={players} mySeat={mySeat} />
          )}

          {(match.status === 'active' || match.status === 'finished') && state && (
            <>
              <div
                className="arena"
                style={{ '--cols': state.board.w, '--rows': state.board.h } as React.CSSProperties}
              >
                <RoyaleBoard
                  state={state}
                  mySeat={mySeat}
                  selected={selected}
                  reachable={reachable}
                  targets={targets}
                  watching={watching || match.status !== 'active'}
                  blow={blow}
                  menu={menu}
                  onUnitClick={onUnitClick}
                  onTileClick={onTileClick}
                  onTreeClick={onTreeClick}
                />
              </div>

              <div className="actionbar">
                {match.status === 'finished' ? (
                  <div className="verdict">
                    {match.draw
                      ? t('royale.stalemateDraw')
                      : winner
                        ? (forfeited
                          ? t('royale.forfeitWinnerIs', { name: winner.username })
                          : t('royale.winnerIs', { name: winner.username }))
                        : t('royale.matchOver')}
                  </div>
                ) : myTurn ? (
                  <>
                    <button
                      className="btn primary" disabled={busy}
                      onClick={() => act(() => endRoyaleTurn(matchId))}
                    >
                      {t('royale.endTurn')}
                    </button>
                    <span className="hint">
                      {t('match.pickThenMenu', {
                        left: actsCapNow - actsSpent, cap: actsCapNow, word: t('match.go'),
                      })}
                    </span>
                  </>
                ) : (
                  <span className="hint">
                    {watching ? t('match.spectating') : t('match.waitingOpponent')}
                  </span>
                )}
              </div>
            </>
          )}
        </main>

        <BattleLog log={state?.log ?? []} open={rail === 'log'} />

        <nav className="railtabs" role="tablist" aria-label={t('common.sidePanels')}>
          <button
            role="tab"
            aria-selected={rail === 'chat'}
            onClick={() => setRail((r) => (r === 'chat' ? null : 'chat'))}
          >
            {t('rail.chat')}{messages.length > 0 ? ` (${messages.length})` : ''}
          </button>
          <button
            role="tab"
            aria-selected={rail === 'log'}
            onClick={() => setRail((r) => (r === 'log' ? null : 'log'))}
          >
            {t('rail.log')}
          </button>
        </nav>
      </div>
    </div>

    {confirmAttack && (
      <Modal title={t('board.friendlyFireConfirm')} onClose={() => setConfirmAttack(null)}>
        <div className="actionbar">
          <button className="btn ghost" onClick={() => setConfirmAttack(null)}>
            {t('common.cancel')}
          </button>
          <button
            className="btn danger"
            onClick={() => {
              act(() => submitRoyaleAttack(matchId, confirmAttack.unit, confirmAttack.target))
              setConfirmAttack(null)
              setMode(null)
            }}
          >
            {t('board.friendlyFireYes')}
          </button>
        </div>
      </Modal>
    )}
    </>
  )
}
