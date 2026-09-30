import { useEffect, useMemo, useRef, useState } from 'react'
import { BattleLog } from './BattleLog'
import { Board } from './Board'
import { TreeBigCard, UnitBigCard } from './BigCard'
import { RoyaleChat } from './RoyaleChat'
import { PlayerCard } from './PlayerCard'
import { GoPips } from './GoPips'
import { Avatar } from './Avatar'
import { RoyaleDeployRoom, RoyaleWaitingRoom } from './RoyaleLobby'
import { useRoyaleMatch, useRoyaleMessages, useRoyalePlayers } from '../lib/useRoyaleMatch'
import { useServerClock } from '../lib/useMatch'
import { useRoyaleLink } from '../lib/useRoyaleLink'
import {
  endRoyaleTurn, forceTimeoutRoyale, leaveRoyaleMatch, royaleBotStep, submitRoyaleAbility,
  submitRoyaleAttack, submitRoyaleDefend, submitRoyaleMove, submitRoyaleThrow,
  submitRoyaleUndoMove, submitRoyaleWait,
} from '../lib/api'
import { royaleActsCap, royaleZone } from '../lib/rulesRoyale'
import { royaleAsMatch, royaleSides } from '../lib/royaleView'
import { isSwamped } from '../lib/swamp'
import { DEPLOY_SECONDS, TURN_SECONDS, type Profile } from '../lib/types'
import { nameColorStyle } from '../lib/nameColors'
import { useT } from '../lib/i18n'
import { Modal } from './Modal'
import { XpGain } from './XpGain'
import { CrownBreak, CROWN_BREAK_MS } from './CrownBreak'
import { TurnBand } from './TurnBand'
import { RoyaleVsIntro } from './VsIntro'

const SEAT_VAR = ['--you', '--foe', '--good', '--kw']

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
  // The card being pointed at, and the one held down on a touch screen -- the
  // same pair 1v1's Match.tsx keeps, for the same reasons.
  const [hovered, setHovered] = useState<string | null>(null)
  const [peeked, setPeeked] = useState<string | null>(null)
  // True while a fight is on screen (Board reports it). Held so a bot does not
  // play its whole turn behind a cinematic.
  const [fightOn, setFightOn] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [rail, setRail] = useState<'chat' | 'log' | null>(null)
  // Whose profile card is open (a chat name was pressed).
  const [viewPlayer, setViewPlayer] = useState<string | null>(null)
  // Whose side a WATCHER (a spectator, or a player who is out) is looking from.
  // null = the default; the "Flip view" button steps through the seats.
  const [viewSeat, setViewSeat] = useState<number | null>(null)
  // Leaving a match in progress eliminates you -- ask first.
  const [confirmLeave, setConfirmLeave] = useState(false)
  const [now, setNow] = useState(Date.now())
  const firedFor = useRef<string>('')
  // The turn-announcement band -- same component, same rules as 1v1's
  // Match.tsx (see TurnBand.tsx and that file's own comment on the
  // detector effect below, which this one is a direct twin of). No VS
  // intro to wait for here -- royale never shows one -- so this is simply
  // gated on the match being active.
  const [turnBand, setTurnBand] = useState<
    { sig: string; name: string; avatar: string | null; color: string | null; isMine: boolean } | null
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

  // Same reset, for the results Modal/crown-break pair below: RoyaleMatch is
  // never remounted between matches (see this file's own top comment), so
  // without this a stale `resultsOpen`/`crownBreak` from the match just left
  // could still be true for a beat on the new one.
  const openedResultsFor = useRef<string | null>(null)
  const [resultsOpen, setResultsOpen] = useState(false)
  const [crownBreak, setCrownBreak] = useState(false)
  useEffect(() => {
    openedResultsFor.current = null
    setResultsOpen(false)
    setCrownBreak(false)
    setViewSeat(null)
    setConfirmLeave(false)
    setSelected(null); setHovered(null); setPeeked(null)
  }, [matchId])

  const me = players.find((p) => p.user_id === profile.id)
  const mySeat = me?.seat ?? null
  const watching = mySeat === null || Boolean(me?.eliminated)
  // A live match this player is still in: walking out of it eliminates them.
  const liveAsPlayer = mySeat !== null && !me?.eliminated
    && (match?.status === 'deploying' || match?.status === 'active')
  const othersAreHuman = players.some((p) => p.user_id && p.user_id !== profile.id)
  // The seat the board is drawn from. A player: their own. A watcher: the one
  // they picked, else their own (if they were playing) or the bottom-left seat.
  const defaultSeat = players.some((p) => p.seat === 2) ? 2 : (players[0]?.seat ?? 0)
  const pov = watching ? (viewSeat ?? mySeat ?? defaultSeat) : mySeat
  // Seats 0 and 1 hold the top of the board; royaleAsMatch/Board turn the picture
  // for them, so whoever is being looked from is always at the bottom -- players
  // and watchers alike, the way 1v1's host and Flip view do it.
  function flipView() {
    const pool = players.filter((p) => !p.eliminated)
    const seats = (pool.length ? pool : players).map((p) => p.seat)
    if (seats.length === 0) return
    const at = seats.indexOf(pov ?? -1)
    setViewSeat(seats[(at + 1) % seats.length])
  }

  function leave() {
    leaveRoyaleMatch(matchId)
    onLeave()
  }
  // The lobby button: a match you are still in asks first, because leaving it
  // takes you out of the game for good.
  function tryLeave() {
    if (liveAsPlayer) setConfirmLeave(true)
    else leave()
  }

  // 1v1's `guard`: one action at a time, and the board stays locked for the
  // whole round trip, so a second click cannot land before the first one's
  // result has been drawn (that is how a fight scene gets skipped).
  async function act(fn: () => Promise<unknown>) {
    setBusy(true); setErr(null)
    try {
      await fn()
      await refresh()
    } catch (e) {
      setErr((e as Error).message)
      await refresh()
      setTimeout(() => setErr(null), 3500)
    } finally {
      setBusy(false)
    }
  }

  const state = match?.state
  const deploying = match?.status === 'deploying'
  const myTurn = Boolean(state && mySeat !== null && state.turn === mySeat && match?.status === 'active')

  // Clear the selection/menu whenever the turn flips -- same rule 1v1's
  // Match.tsx uses (`useEffect(() => setSelected(null), [state?.turn, ...])`.
  useEffect(() => {
    setSelected(null); setPeeked(null)
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
    setTurnBand({
      sig, name: p.username, avatar: p.avatar, color: p.name_color ?? null,
      isMine: p.seat === mySeat,
    })
  }, [match, state?.turn, state?.turnNumber, players, showVsIntro])

  // The turn's budget. 0061 fixed royale's cap at one activation, always --
  // see royaleActsCap()'s own comment on why that is a named export rather
  // than a literal scattered at every call site.
  const actsCapNow = royaleActsCap()
  const actsSpent = Math.min(actsCapNow, state?.acts ?? 0)

  const onClock = match?.status === 'active' || deploying
  // "Reconnecting..." -- who at the table looks disconnected (players and
  // watchers both see it, and it never covers the board).
  const link = useRoyaleLink(matchId, onClock, mySeat)
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
    // Per deadline, like Match.tsx: a resolved pending throw deals a new clock
    // inside the same turn, and that one has to be asked for too.
    const stamp = `${match.id}:${match.status}:${state?.turnNumber}:${match.turn_deadline}`
    if (remaining < -1.2 && firedFor.current !== stamp) {
      firedFor.current = stamp
      forceTimeoutRoyale(match.id).then(refresh)
    }
  }, [remaining, match, onClock, state?.turnNumber, refresh])

  // 0052: whoever currently holds the turn, if that seat is a bot, gets
  // driven the same way Match.tsx drives the 1v1 bot -- one action per
  // call, on a delay, re-firing whenever match.updated_at changes so the
  // chain stops on its own the moment the turn moves on.
  // 0179: the tornado's decision belongs to whoever raised it, on anyone's
  // turn -- so a bot holding one has to be driven even when it is not its turn.
  const pendingSeat = state?.pending ? state.pending.side : null
  const turnSeat = pendingSeat !== null && players.find((p) => p.seat === pendingSeat)?.bot != null
    ? pendingSeat
    : (state?.turn ?? null)
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
    && !showGetReady && !showVsIntro && !fightOn,
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

  // Crown-break beat, then the results Modal -- 1v1's Match.tsx twin of this
  // effect (see its own comment). `match.status` flipping to 'finished' only
  // happens once the LAST king falls (an individual seat's king dying just
  // sets that royale_players row's `eliminated`, not the match itself), so
  // "don't show until the last king" is already guaranteed server-side --
  // this only has to decide WHEN to show it once that happens: skip the
  // crown break for a draw/stalemate (match.draw, 0051 -- no crown fell),
  // and if the winning seat's player row hasn't loaded into `players` yet
  // (a real but narrow race -- same one the turn-band detector effect above
  // already guards against with its own "players hasn't loaded yet -- try
  // again once it has" comment), wait rather than opening on a missing name.
  useEffect(() => {
    if (match?.status !== 'finished' || openedResultsFor.current === match.id) return
    if (match.draw) {
      openedResultsFor.current = match.id
      setResultsOpen(true)
      return
    }
    const w = players.find((p) => p.seat === match.winner_seat)
    if (!w) return // players hasn't loaded yet -- this effect re-runs once it has
    openedResultsFor.current = match.id
    setCrownBreak(true)
    const id = setTimeout(() => {
      setCrownBreak(false)
      setResultsOpen(true)
    }, CROWN_BREAK_MS)
    // Same fast-unmount safety as Match.tsx's own twin of this effect.
    return () => clearTimeout(id)
  }, [match?.status, match?.id, match?.draw, match?.winner_seat, players])

  // 0179: Battle Royale is drawn by 1v1's own Board. It is handed the table
  // as a two-sided board from `pov`'s seat (see royaleView.ts): your units
  // against everyone else's. What it lights up, what it animates, what it
  // offers in its menu -- moves, strikes, defends, summons, traps, the
  // tornado's throw, undo -- is all the same code 1v1 runs.
  const view = useMemo(
    () => (state
      ? royaleAsMatch(state, pov, {
        finished: match?.status === 'finished', draw: Boolean(match?.draw),
      })
      : null),
    [state, pov, match?.status, match?.draw],
  )
  const { mine: mineSide } = royaleSides(pov)
  const playing = !watching && match?.status === 'active'
  // Whose quarter of the ground is tinted as "yours".
  const tileMine = useMemo(() => {
    const z = pov === null ? null : royaleZone(pov)
    return (x: number, y: number) => Boolean(z && x >= z[0] && x <= z[1] && y >= z[2] && y <= z[3])
  }, [pov])

  const unitAt = (id: string | null) => (id ? view?.units.find((u) => u.id === id) : undefined)
  const treeAt = (id: string | null) => (id ? (view?.obstacles ?? []).find((o) => o.id === id) : undefined)

  const pinnedUnit = unitAt(selected)
  const pinnedCard = view && pinnedUnit
    ? <UnitBigCard unit={pinnedUnit} side="left" pinned swamped={isSwamped(view, pinnedUnit)} />
    : null
  const hoverId = hovered && hovered !== selected ? hovered : null
  const hoverUnit = unitAt(hoverId)
  const hoverTree = treeAt(hoverId)
  const hoverCard = view && hoverUnit
    ? <UnitBigCard unit={hoverUnit} side="right" swamped={isSwamped(view, hoverUnit)} />
    : hoverTree ? <TreeBigCard tree={hoverTree} side="right" /> : null
  const peekUnit = unitAt(peeked)
  const peekTree = treeAt(peeked)
  const peekCard = view && peekUnit
    ? <UnitBigCard unit={peekUnit} side="peek" swamped={isSwamped(view, peekUnit)} />
    : peekTree ? <TreeBigCard tree={peekTree} side="peek" /> : null

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
  // ...and a player walking out of the match writes "left the match" instead.
  const walkedOut = recentLog.some((e) => e.text.includes('left the match'))
  const winKey = walkedOut ? 'royale.leftWinnerIs' : forfeited ? 'royale.forfeitWinnerIs' : 'royale.winnerIs'
  // The seat the chip counts down for: one whose player looks disconnected,
  // preferring the one whose turn it is (their clock is the one running).
  const awaySeat = link.away.includes(state?.turn ?? -1) ? (state?.turn ?? null) : (link.away[0] ?? null)
  const awayRow = awaySeat === null ? null : players.find((p) => p.seat === awaySeat) ?? null
  const awayName = awayRow?.username ?? ''
  const pct = remaining === null ? 0 : Math.max(0, Math.min(1, remaining / clockLength))
  const urgent = remaining !== null && remaining <= 8

  return (
    <>
    <div className="match">
      <header className="matchbar">
        <button className="linkbtn" onClick={tryLeave}>{t('common.leave')}</button>

        <ul className="rmatch-seats">
          {players.map((p) => (
            <li
              key={p.seat}
              className={`rmatch-seat${p.eliminated ? ' is-out' : ''}${state?.turn === p.seat ? ' is-turn' : ''}${watching && pov === p.seat && match.status !== 'waiting' && match.status !== 'deploying' ? ' is-view' : ''}`}
            >
              <span className="rseat-dot" style={{ background: `var(${SEAT_VAR[p.seat]})` }} aria-hidden="true" />
              {/* A person has a profile to open (add them, see their card);
                  a bot has none. */}
              {p.user_id
                ? (
                  <button
                    type="button" className="rseat-namebtn"
                    style={nameColorStyle(p.name_color)}
                    onClick={() => setViewPlayer(p.user_id)}
                  >
                    {p.username}
                  </button>
                )
                : <span style={nameColorStyle(p.name_color)}>{p.username}</span>}
              {p.bot != null && <span className="rseat-bot-tag">{t('royale.botTag')}</span>}
            </li>
          ))}
        </ul>

        <div className="matchbar-right">
          {/* "Reconnecting..." -- says THAT a player is having trouble, never
              what (a reload, a closed tab and a lost signal all read the same),
              and lives up here in the bar so nothing covers the board. The rule
              behind it is the ordinary AFK one: two of THEIR turns running out
              with no action and they are out. The pips count those, the seconds
              are the clock on their current turn. Watchers get it too. */}
          {match.status !== 'finished' && (link.offline || awaySeat !== null) && (
            <span
              className={`linkchip${link.offline ? ' is-self' : ''}`}
              role="status" aria-live="polite"
              title={link.offline ? undefined : t('royale.reconnectingRule')}
            >
              <span className="linkchip-spin" aria-hidden="true" />
              <span className="linkchip-text">
                {link.offline
                  ? t('match.youOffline')
                  : link.away.length > 1
                    ? t('royale.playersReconnecting', { n: link.away.length })
                    : t('royale.playerReconnecting', { name: awayName })}
              </span>
              {!link.offline && awaySeat !== null && match.status === 'active' && (
                <>
                  <span
                    className="linkchip-pips" role="img"
                    aria-label={t('match.missedTurns', { n: Math.min(2, awayRow?.idle_streak ?? 0) })}
                  >
                    {[0, 1].map((i) => (
                      <i key={i} className={i < (awayRow?.idle_streak ?? 0) ? 'is-missed' : ''} />
                    ))}
                  </span>
                  {state?.turn === awaySeat && remaining !== null && (
                    <span className="linkchip-secs">{Math.max(0, Math.ceil(remaining))}s</span>
                  )}
                </>
              )}
            </span>
          )}
          <button
            className="roomcode"
            title={t('match.copyCode')}
            onClick={() => navigator.clipboard?.writeText(match.code)}
          >
            {match.code}
          </button>
          {watching && <span className="pill spectating">{t('match.watching')}</span>}
          {watching && (match.status === 'active' || match.status === 'finished') && players.length > 1 && (
            <button
              type="button" className="btn tiny ghost flipview"
              onClick={flipView}
              title={t('match.flipViewTitle', {
                name: (() => {
                  const pool = players.filter((p) => !p.eliminated)
                  const seats = (pool.length ? pool : players)
                  const at = seats.findIndex((p) => p.seat === pov)
                  return seats[(at + 1) % seats.length]?.username ?? ''
                })(),
              })}
            >
              {t('match.flipView')}
            </button>
          )}
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
          isMine={turnBand.isMine}
          onDone={() => setTurnBand((b) => (b?.sig === turnBand.sig ? null : b))}
        />
      )}

      {crownBreak && <CrownBreak key={matchId} />}

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
        </div>
      )}

      {err && <div className="toast">{err}</div>}

      <div className="stage">
        <RoyaleChat
          matchId={matchId} profile={profile} messages={messages} open={rail === 'chat'}
          onViewPlayer={setViewPlayer}
        />

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
                {pinnedCard}
                {hoverCard}
                {peekCard && (
                  <div className="peekscrim" onPointerDown={() => setPeeked(null)} aria-hidden="true" />
                )}
                {peekCard}
                {view && (
                  <Board
                    state={view}
                    matchId={matchId}
                    unitSkins={Object.fromEntries(players.map((p) => [String(p.seat), p.equipped_unit_skin]))}
                    mySide={playing ? mineSide : null}
                    viewSide={playing ? null : mineSide}
                    tileMine={tileMine}
                    isMyTurn={myTurn}
                    deploying={false}
                    selectedId={selected}
                    onSelect={setSelected}
                    onMove={(x, y) => selected && act(() => submitRoyaleMove(matchId, selected, x, y))}
                    onAttack={(target) => selected && act(() => submitRoyaleAttack(matchId, selected, target))}
                    onAbility={(unitId, target) => act(() => submitRoyaleAbility(matchId, unitId, target))}
                    onThrow={(target) => act(() => submitRoyaleThrow(matchId, target))}
                    onDefend={(targetId) => selected && act(() => submitRoyaleDefend(matchId, selected, targetId))}
                    onWait={() => act(() => submitRoyaleWait(matchId))}
                    onUndoMove={() => act(() => submitRoyaleUndoMove(matchId))}
                    onDeploy={() => undefined}
                    onHover={setHovered}
                    onPeek={setPeeked}
                    onWatching={setFightOn}
                    introOpen={showGetReady || showVsIntro}
                    locked={Boolean(turnBand) || busy}
                  />
                )}
              </div>

              <div className={`unitbar is-goes${match.status === 'active' && !match.draw ? '' : ' is-idle'}`}>
                {match.status === 'active' && !match.draw && (
                  <GoPips cap={actsCapNow} spent={actsSpent} theirs={liveAsPlayer && !myTurn} />
                )}
              </div>

              <div className="actionbar">
                {match.status === 'finished' ? (
                  <>
                    {/* The rich version -- a results Modal -- opens itself
                        the instant the match finishes (see the effect
                        above). This strip is what is left once it is open
                        (nothing more; the board speaks for itself) or once
                        the player has dismissed it and wants it back --
                        same shape as Match.tsx's own "View results". */}
                    <div className="verdict">
                      {match.draw
                        ? t('royale.stalemateDraw')
                        : winner
                          ? t(winKey, { name: winner.username })
                          : t('royale.matchOver')}
                    </div>
                    {!resultsOpen && (
                      <button className="btn primary" onClick={() => setResultsOpen(true)}>
                        {t('match.viewResults')}
                      </button>
                    )}
                  </>
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

    {/* The results popup -- Match.tsx's own chess.com-style modal, brought
        to Royale. Opens itself once the match finishes (see the effect
        above, and crownBreak right before it) and stays reachable
        afterwards through the "View results" button in the condensed
        .verdict strip once dismissed. Reuses .matchend -- the same shape
        1v1 uses -- but none of that block's RP/rating/AdvantageChart
        children, which are all specific to a two-player rated match and
        have nothing to read here; Royale's own verdict text (draw/winner/
        forfeit, already computed above for the inline strip) becomes the
        Modal's title instead, same as 1v1's own winner headline does. */}
    {resultsOpen && match.status === 'finished' && (
      <Modal
        title={match.draw
          ? t('royale.stalemateDraw')
          : winner
            ? t(winKey, { name: winner.username })
            : t('royale.matchOver')}
        onClose={() => setResultsOpen(false)}
      >
        <div className="matchend">
          {liveAsPlayer && <XpGain userId={profile.id} refKey={`r:${match.id}`} xp={profile.xp} />}
          {/* Everyone who sat down at this table -- players and watchers alike
              can open their profile (add them, see their card). Bots have no
              profile. No points here: Battle Royale is not rated. */}
          <div className="matchend-players">
            {players.map((p) => {
              const inner = (
                <>
                  <Avatar slug={p.avatar} name={p.username} size={28} />
                  <span style={nameColorStyle(p.name_color)}>
                    {p.seat === match.winner_seat && !match.draw ? '♛ ' : ''}{p.username}
                  </span>
                </>
              )
              return p.user_id ? (
                <button key={p.seat} type="button" className="matchend-player" onClick={() => setViewPlayer(p.user_id)}>
                  {inner}
                </button>
              ) : (
                <span key={p.seat} className="matchend-player is-bot">{inner}</span>
              )
            })}
          </div>
          <div className="matchend-actions">
            <button className="btn ghost" onClick={leave}>
              {t('match.goToLobby')}
            </button>
          </div>
        </div>
      </Modal>
    )}

    {confirmLeave && (
      <Modal
        title={t(othersAreHuman ? 'royale.confirmLeaveLive' : 'match.confirmLobby')}
        onClose={() => setConfirmLeave(false)}
      >
        <div className="actionbar">
          <button className="btn ghost" onClick={() => setConfirmLeave(false)}>
            {t('common.cancel')}
          </button>
          <button className="btn danger" onClick={() => { setConfirmLeave(false); leave() }}>
            {t('match.confirmLobbyYes')}
          </button>
        </div>
      </Modal>
    )}

    {viewPlayer && (
      // Royale has no room to walk into from here, so no 1 vs 1 invite: this
      // is the card for looking at someone and adding them as a friend.
      <PlayerCard
        userId={viewPlayer} me={profile} onClose={() => setViewPlayer(null)}
        canInvite={false} onEnter={() => setViewPlayer(null)}
      />
    )}
    </>
  )
}
