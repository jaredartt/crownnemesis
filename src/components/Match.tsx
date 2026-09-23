import { useEffect, useMemo, useRef, useState } from 'react'
import { AddFriendButton } from './AddFriendButton'
import { Board } from './Board'
import { Chat } from './Chat'
import { BattleLog } from './BattleLog'
import { TreeBigCard, UnitBigCard } from './BigCard'
import { useMatch, useMessages, useServerClock } from '../lib/useMatch'
import { useGhost } from '../lib/useGhost'
import { isSwamped } from '../lib/swamp'
import {
  botStep, claimWin, declineRematch, deployUnit, endTurn, forceTimeout, getMatchIntroProfiles,
  getMatchResult, leaveMatch, leaveRanked, myDeploy, rankedTick, requestRematch, resignMatch, setReady,
  submitAbility, submitAttack, submitDefend, submitMove, submitThrow, submitWait, theirArmy,
  type MatchIntroProfile, type MatchResult,
} from '../lib/api'
import {
  DEPLOY_SECONDS, TURN_SECONDS, actsCap, reachText,
  type MatchState, type Profile, type Side, type Unit,
  unitPower,
} from '../lib/types'
import { abilityText, useT } from '../lib/i18n'
import { afflictionsOf } from '../lib/effects'
import { Ability } from './Ability'
import { Avatar } from './Avatar'
import { VsIntro } from './VsIntro'
import { TurnBand } from './TurnBand'
import { KingdomSwitch } from './KingdomSwitch'
import { nameColorStyle } from '../lib/nameColors'
import { useCardsBySlug } from '../lib/useCards'
import { playLose, playTurn, playWin } from '../lib/sfx'
import { Modal } from './Modal'
import { AdvantageChart, type AdvantagePoint } from './AdvantageChart'

// How often a missed bot attempt gets retried -- see the effect below.
const BOT_RETRY_MS = 2000
// Jared: the whole arrival sequence was in the wrong order -- the VS screen
// used to show at the END of deployment, right as the fight itself began.
// It opens the room now instead, the instant it exists ('deploying'), with
// this one-second "Get ready!" beat in front of it so the VS screen itself
// never feels like the very first thing that happens. See the effect below
// and Board.tsx's own `introOpen`-gated board-build/army-landing chain,
// which is what everything after the VS screen closes is really waiting on.
const GET_READY_MS = 1000

export function Match({ matchId, profile, onProfile, onLeave, onGoTo }: {
  matchId: string
  profile: Profile
  onProfile: (patch: Partial<Profile>) => void
  onLeave: () => void
  onGoTo: (id: string) => void
}) {
  function leave() {
    // Tell the server first so an emptied room disappears at once rather than
    // waiting for the sweep. Closing the tab instead is covered by the sweep.
    leaveMatch(matchId)
    onLeave()
  }

  const t = useT()
  // Only for the ability sentence: a unit's numbers come from the snapshot in
  // matches.state, which is correct, and its words come from the card row,
  // which is where a translation written after the match began can reach it.
  const bySlug = useCardsBySlug()
  const { match, refresh } = useMatch(matchId)
  const messages = useMessages(matchId)
  const clockOffset = useServerClock()

  const [selected, setSelected] = useState<string | null>(null)
  const [hovered, setHovered] = useState<string | null>(null)
  // The one being held down on a touch screen. Separate from `hovered`
  // because a phone can have one and never the other, and a desktop the
  // reverse -- and because a card that arrives under a finger goes in the
  // middle of the screen rather than against an edge.
  const [peeked, setPeeked] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [now, setNow] = useState(Date.now())
  // Which rail is showing. Only meaningful on a narrow screen, where the two
  // side panels become tabs instead of columns -- there is no room for both,
  // and a phone should never have to scroll a match.
  // null means neither is showing. On a phone the rails are a sheet that slides
  // over the board rather than a column beside it, and the board is what you
  // came for -- so nothing covers it until you ask.
  const [rail, setRail] = useState<'chat' | 'log' | null>(null)
  // Your own four during deployment. They are not in the match row -- the row
  // is readable by everyone, and a setup you can read is a setup you can play
  // against -- so they arrive through a function that will only ever hand you
  // your own side.
  const [myUnits, setMyUnits] = useState<Unit[] | null>(null)
  const [theirs, setTheirs] = useState<Unit[] | null>(null)
  // Shown once, the first time a match becomes a match. Held in a ref keyed
  // by match id rather than in state, because a rematch is a NEW id in the
  // same mounted component and the board's own state is what tells them
  // apart -- a boolean would open the second match with the first one's
  // proclamation already spent.
  const [showVsIntro, setShowVsIntro] = useState(false)
  // The one-second beat in front of it -- see GET_READY_MS above.
  const [showGetReady, setShowGetReady] = useState(false)
  // Only asked against a bot -- see the button below. A human opponent is
  // told nothing by you leaving (the room just sits there for the sweep),
  // so there is nothing irreversible to confirm; a bot match ends the
  // instant you go, which is the one case Jared asked this for.
  const [confirmLobby, setConfirmLobby] = useState(false)
  // Jared: "Before surrendering any battle in any mode against anyone,
  // there should be a confirmation pop-up... 'Are you sure you want to
  // forfeit?'" -- only the ACTIVE-match Resign button below, not the
  // deployment-phase Leave button right above it in the JSX (same
  // resignMatch() call, but nothing has actually started yet to forfeit).
  const [confirmResign, setConfirmResign] = useState(false)
  // Jared: leaving during deployment in a RANKED match is not the free out
  // the old comment above assumed -- resign_match() rates it exactly like a
  // mid-battle resignation (see 0066_temp_lp_from_friends_and_tournaments.sql,
  // "was `if m.ranked then` alone"), so a misclick here costs real RP with
  // no warning at all. Scoped to ranked, matching what Jared actually asked
  // for -- a casual room still has nothing at stake to confirm.
  const [confirmLeaveDeploy, setConfirmLeaveDeploy] = useState(false)

  // ---- match end: the RP swing this match produced, if any ----------------
  const [matchResult, setMatchResult] = useState<MatchResult | null>(null)
  const fetchedResultFor = useRef<string | null>(null)
  // ---- match end: a turn-by-turn read of who was ahead --------------------
  const [advHistory, setAdvHistory] = useState<AdvantagePoint[]>([])
  const initialMaxHp = useRef<{ host: number; guest: number } | null>(null)
  // ---- match end: the popup itself -----------------------------------------
  const [resultsOpen, setResultsOpen] = useState(false)
  const openedResultsFor = useRef<string | null>(null)
  // A rematch or "find another opponent" points this same component at a new
  // matchId without ever unmounting it (see wentTo/goTo below) -- everything
  // above has to start over for the new room, the same reason Board.tsx
  // resets its own reveal state on a matchId change rather than a remount.
  const prevResultsMatchId = useRef(matchId)
  if (matchId !== prevResultsMatchId.current) {
    prevResultsMatchId.current = matchId
    fetchedResultFor.current = null
    initialMaxHp.current = null
    if (matchResult) setMatchResult(null)
    if (advHistory.length > 0) setAdvHistory([])
    if (resultsOpen) setResultsOpen(false)
  }
  // ---- "find another opponent", straight from the results popup -----------
  // Exactly Lobby.tsx's own ranked queue effect (rankedTick every 2s, drop
  // out after 25s of nobody calling it) -- reimplemented here rather than
  // shared, since going through Lobby at all would mean unmounting this
  // whole match screen and losing the popup it is trying to keep open.
  // Finding someone hands off through the SAME goTo() a rematch uses, so
  // this component is never unmounted either -- one continuous "next game"
  // feel, chess.com's own trick for the same button.
  const [findingNext, setFindingNext] = useState(false)
  const [findWaiting, setFindWaiting] = useState(0)
  const findSince = useRef(0)
  const [findElapsed, setFindElapsed] = useState(0)
  const opened = useRef<string | null>(null)
  // Mirrors `showVsIntro`, but as a REF -- read synchronously by the turn-
  // band effect below, in the SAME commit that decides to show VsIntro,
  // rather than through `showVsIntro`'s own state closure. Jared: "the Vs
  // screen overlaps with the turn black band". Root cause: on the very
  // first render, BOTH the VsIntro-triggering effect and the turn-band
  // effect run in the same pass, off the same (pre-update) render's state --
  // so the turn-band effect was reading `showVsIntro` as still `false` (this
  // render's value) even though the sibling effect had, moments earlier in
  // that same pass, already decided to flip it true for the NEXT render.
  // That let the band fire immediately, one render before VsIntro actually
  // appeared, instead of waiting for it. A ref has no such lag -- it is set
  // and read synchronously, so whichever effect runs second in a given pass
  // always sees what the first one just decided.
  const introWanted = useRef(false)
  const firedFor = useRef<string>('')
  // 0060: name colors, fetched live by id the same way VsIntro already
  // fetches avatar/featured_achievements -- not frozen onto `matches`, so a
  // color picked mid-match still shows before this one ends.
  const [nameColors, setNameColors] = useState<Record<string, MatchIntroProfile>>({})
  // The turn-announcement band (Jared: a black band naming whose turn it is,
  // at the start of every turn, in every mode). `sig` is what the detector
  // effect below compares against -- `${turn}:${turnNumber}` -- and doubles
  // as the `key` TurnBand mounts under, so a new turn's band is a fresh
  // mount (a clean replay of its own appear/hold/leave) rather than a prop
  // change on a band that never left.
  const [turnBand, setTurnBand] = useState<
    { sig: string; name: string; avatar: string | null; color: string | null } | null
  >(null)
  // What signature this component has already announced, so a re-render
  // that changes nothing about the turn (the clock ticking, a hover) never
  // re-fires it -- same "ref outlives renders, state drives the UI" split
  // Board.tsx's own reveal system uses.
  const turnBandSeen = useRef<string | null>(null)

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 200)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    let alive = true
    const ids = [match?.host_id, match?.guest_id].filter((x): x is string => Boolean(x))
    if (ids.length > 0) getMatchIntroProfiles(ids).then((p) => { if (alive) setNameColors(p) })
    return () => { alive = false }
  }, [match?.host_id, match?.guest_id])

  const mySide: Side | null = !match
    ? null
    : match.host_id === profile.id
      ? 'host'
      : match.guest_id === profile.id
        ? 'guest'
        : null

  const state = match?.state
  const deploying = match?.status === 'deploying'
  const isMyTurn = Boolean(match && mySide && match.status === 'active' && state?.turn === mySide)
  // What the board draws. During deployment that is your half and the trees;
  // the other half is genuinely empty, because nothing else has been sent.
  const shown: MatchState | undefined =
    state && match?.status === 'deploying' ? { ...state, units: myUnits ?? [] } : state
  const selectedUnit = shown?.units.find((u) => u.id === selected) ?? null
  const iAmReady = Boolean(mySide && state?.ready?.[mySide])
  const theirSide: Side | null = mySide === 'host' ? 'guest' : mySide === 'guest' ? 'host' : null

  // Read off the row rather than kept in this component: an invitation has to
  // survive a reload, and both players have to see the same one.
  const iAsked = Boolean(match && mySide && match[`rematch_${mySide}` as const])
  const theyAsked = Boolean(match && theirSide && match[`rematch_${theirSide}` as const])
  const challenged = Boolean(
    theyAsked && !iAsked && match?.bot == null && !match?.next_match_id && mySide,
  )
  // They have missed three of their own turns in a row. Nothing has been
  // decided by that -- it only puts a button in front of the other player.
  const theyAreAway = Boolean(
    theirSide && state?.away === theirSide && match?.status === 'active' && match?.bot == null,
  )
  // Held while a fight is on screen -- see Board's onWatching.
  const [watching, setWatching] = useState(false)
  // Jared: "Vs screen -> turn black band -> then play, one after another,
  // and the bot shouldn't do anything until the last thing has completely
  // finished." `!turnBand` holds this false for as long as this turn's own
  // band is still up (see that ref's own comment above), and `!showVsIntro`
  // does the same for the VS screen that comes before it -- WITHOUT this,
  // a playtest caught the bot moving while the VS screen (still fixed,
  // still full-screen, still blocking every HUMAN click via its own
  // pointerdown handler) sat on top of the board: the overlay stops a
  // player from clicking through it, but stops nothing at all for a bot,
  // whose "turn" is just this boolean deciding whether to fire an effect,
  // never a click. `turnBand` alone was not enough to catch that, because
  // the band-detector effect is ITSELF gated on `introWanted` and never
  // sets `turnBand` while the VS screen is still wanted -- so during the
  // VS screen, `turnBand` is null, `!turnBand` is true, and nothing but
  // this added check was stopping the bot's own effect from starting.
  const botTurn = Boolean(
    match?.bot != null && match.status === 'active' && state?.turn === 'guest'
    && !state?.winner && !watching && !turnBand && !showVsIntro,
  )

  // Where they are looking, and a way to tell them where we are. Only while
  // the match is genuinely running: during deployment a pointer would give the
  // setup away a tile at a time, and a finished board has nothing to watch.
  // A bot has no pointer, so there is nothing to join for.
  const ghostLive = Boolean(
    match?.status === 'active' && !state?.winner && match?.bot == null,
  )
  const { ghost, look } = useGhost(matchId, mySide, ghostLive)

  // The turn's budget. It belongs to whoever is to move -- there is only one
  // of it -- so this is as true while you are watching them spend it as while
  // you are spending it yourself.
  const actsCapNow = state ? actsCap(state) : 2
  const actsSpent = Math.min(actsCapNow, state?.acts ?? 0)
  const actsLeft = actsCapNow - actsSpent

  const onClock = match?.status === 'active' || deploying
  const clockLength = deploying ? DEPLOY_SECONDS : TURN_SECONDS
  const remaining = useMemo(() => {
    if (!match?.turn_deadline || !onClock) return null
    return (new Date(match.turn_deadline).getTime() - (now + clockOffset)) / 1000
  }, [match?.turn_deadline, onClock, now, clockOffset])

  // Nobody is running a game server, so the clients enforce the clock by
  // *asking* the database to expire the turn. The function refuses unless the
  // deadline has genuinely passed according to Postgres, so this is safe to
  // call from either player or from a spectator.
  useEffect(() => {
    if (!match || !onClock || remaining === null) return
    const stamp = `${match.id}:${match.status}:${state?.turnNumber}`
    if (remaining < -2 && firedFor.current !== stamp) {
      firedFor.current = stamp
      forceTimeout(match.id).then(refresh)
    }
  }, [remaining, match, onClock, state?.turnNumber, refresh])

  useEffect(() => {
    if (!matchId || match?.status !== 'deploying') { setMyUnits(null); return }
    let alive = true
    myDeploy(matchId).then((u) => { if (alive) setMyUnits(u) })
    return () => { alive = false }
  }, [matchId, match?.status])

  // Which five they brought. Fetched once per deployment rather than polled:
  // the answer is fixed the moment the second player arrives -- join_match
  // draws both armies -- so there is nothing to watch for.
  useEffect(() => {
    if (!matchId || match?.status !== 'deploying') { setTheirs(null); return }
    let alive = true
    theirArmy(matchId).then((u) => { if (alive) setTheirs(u) })
    return () => { alive = false }
  }, [matchId, match?.status])

  // Get Ready, then the VS intro -- once per match, at the moment it BECOMES
  // one. Jared: "Finding a match -> Get ready! -> the Vs screen -> the map
  // builds itself... -> your cards... -> you choose... -> opponents'
  // cards... -> the turn black band". Everything from "the map builds
  // itself" onward is Board.tsx's own `introOpen`-gated chain (its own
  // comments walk through it) -- this effect only has to open the door
  // gated on `match?.status === 'deploying'` rather than 'active': that
  // status exists for exactly as long as this is true and never again,
  // so there is no equivalent of the old turnNumber<=1 check to worry
  // about a reconnect replaying it against -- a reconnect mid-deployment
  // finds this same status and gets the same intro a first-time arrival
  // would, which is the one case this can still repeat itself, same as a
  // page refresh during an unfinished VS screen already could.
  //
  // Costs about 3.6s of a match whose deploy clock alone is much longer
  // than that, and is dismissed by any key or click either way.
  useEffect(() => {
    if (!matchId || match?.status !== 'deploying') return
    if (opened.current === matchId) return
    opened.current = matchId
    introWanted.current = true
    setShowGetReady(true)
    const id = setTimeout(() => { setShowGetReady(false); setShowVsIntro(true) }, GET_READY_MS)
    return () => clearTimeout(id)
  }, [matchId, match?.status])

  // The turn band itself. Waits for the VS intro to finish (same reasoning
  // as Board.tsx's own reveal waiting on `introOpen`: playing a ~1.4s
  // announcement underneath a ~2.6s title card means it is over before the
  // title card even clears) and fires once per NEW `turn:turnNumber` pair
  // this component has seen -- which includes turn 1, right after the VS
  // intro closes ("who's actually going first" is exactly the kind of thing
  // worth confirming right there), and includes walking into a match already
  // in progress (a reload, a spectator arriving) rather than only a live
  // flip, since `turnBandSeen` starts null and a mount's first render is a
  // signature it has never announced either -- and telling a returning
  // player whose turn it currently is costs nothing and is never wrong.
  useEffect(() => {
    // `introWanted.current`, not `showVsIntro` -- see that ref's own comment
    // on why the state value alone raced with the sibling effect above.
    if (!match || match.status !== 'active' || !state || introWanted.current) return
    const sig = `${state.turn}:${state.turnNumber}`
    if (turnBandSeen.current === sig) return
    turnBandSeen.current = sig
    const side = state.turn
    const id = side === 'host' ? match.host_id : match.guest_id
    setTurnBand({
      sig,
      name: (side === 'host' ? match.host_name : match.guest_name) ?? '',
      avatar: (id && nameColors[id]?.avatar) || null,
      color: (id && nameColors[id]?.name_color) || null,
    })
  }, [match, state?.turn, state?.turnNumber, showVsIntro, nameColors])

  // The bot plays one action per call, on a delay, so you watch it think
  // instead of finding its whole turn already done. Every step is a fresh
  // decision made by the server against the board as it now stands -- there is
  // no plan held anywhere on this side. `updated_at` changing is what schedules
  // the next one, so the chain stops on its own the moment the turn flips back.
  //
  // RETRIED, not just scheduled once -- see the Royale twin of this effect
  // in RoyaleMatch.tsx for the report that found the gap: a single
  // `setTimeout` only ever gets one shot, and a backgrounded tab (browsers
  // throttle a hidden tab's timers) or a dropped RPC round-trip is enough to
  // burn it, with nothing here to notice and no `updated_at` change coming
  // to reschedule it -- the turn then sits until the clock itself expires.
  // A repeating attempt every BOT_RETRY_MS is the same "realtime is the fast
  // path, the poll underneath is the safety net" idiom useMatch already uses
  // for the match row itself. Retrying is free: `bot_step` reads the live
  // turn under its own row lock and no-ops the instant it is not this bot's
  // turn any more, so a redundant call once the turn has already moved on
  // costs nothing.
  useEffect(() => {
    if (!botTurn || !match) return
    let cancelled = false
    // Jared: fight scenes sometimes not playing, moves sometimes teleporting
    // instead of animating -- traced to two actions landing close enough
    // together that this component's own board skips the state in between
    // (see `guard()`'s own comment on the human side of the same bug). The
    // RETRY here is a safety net for a genuinely dropped call, not a second
    // clock this effect should ever be racing against ITSELF with: without
    // this flag, a `botStep` that's simply slow to answer (the network, not
    // a real failure) would let `BOT_RETRY_MS` fire a SECOND call while the
    // first is still out, which is exactly the "two actions overlap" gap
    // that skips a fight scene or a move animation -- just from the bot's
    // own side rather than a human's.
    const inFlight = { current: false }
    const attempt = () => {
      if (cancelled || inFlight.current) return
      inFlight.current = true
      botStep(match.id).then(refresh).finally(() => { inFlight.current = false })
    }
    // Jared: when the bot goes first, "give it 1 initial second before
    // actually moving... so the player can actually look at the board and
    // plan a little" -- only the match's opening turn, not every one of the
    // bot's turns (an ordinary mid-match 650ms think-pause reads fine once
    // you're already in the swing of a match; it's specifically walking in
    // cold to a board that's already moving that felt instant). Gated on
    // `state?.turnNumber` rather than `match.bot`'s own presence, since a
    // bot match where the HUMAN goes first never runs this branch at all --
    // `botTurn` is false until the turn actually flips to 'guest'.
    const firstDelay = (state?.turnNumber ?? 1) <= 1 ? 1000 : 650
    const first = setTimeout(attempt, firstDelay)
    const retry = setInterval(attempt, BOT_RETRY_MS)
    return () => { cancelled = true; clearTimeout(first); clearInterval(retry) }
  }, [botTurn, match?.id, match?.updated_at, state?.turnNumber, refresh])

  // The rematch is signalled by the finished room pointing at a new one, which
  // arrives over the realtime subscription we are already holding. Whoever
  // asked second created it; both sides get here the same way.
  //
  // The ref is what stops this from firing more than once for the same room,
  // and it is not paranoia. onGoTo used to be a fresh arrow on every App
  // render, so this effect re-ran on every render -- and the clock above
  // re-renders this component five times a second. Each run restarted the
  // crossing, whose swap lands at 310ms, so the swap never got to run: the
  // wipe block covered the screen and stayed there, matchId never changed,
  // and the condition below never went false. That was the blank white page
  // on a practice rematch. onGoTo is stable now and the crossing ignores a
  // second call, but this is the guard that says the intent out loud: go to a
  // given room once.
  const wentTo = useRef<string>('')
  useEffect(() => {
    const next = match?.next_match_id
    if (!next || next === matchId || wentTo.current === next) return
    wentTo.current = next
    leaveMatch(matchId)
    onGoTo(next)
  }, [match?.next_match_id, matchId, onGoTo])

  async function askRematch() {
    setErr(null)
    try {
      const next = await requestRematch(match!.id)
      if (next) goTo(next)
      else await refresh()
    } catch (e) {
      setErr((e as Error).message)
      setTimeout(() => setErr(null), 3500)
    }
  }

  // Clear the selection whenever the turn flips.
  useEffect(() => setSelected(null), [state?.turn, state?.turnNumber])

  // Two announcements, and both of them have to be careful about what counts
  // as news. A turn is news when it becomes yours and was not yours a moment
  // ago -- not on the first render, where the ref is seeded with whatever is
  // already true, or opening a match on your turn would chime at you, and so
  // would every reconnect. The result is news exactly once, for the same
  // reason: the winner sits in the row for as long as the room exists, so a
  // spectator arriving afterwards, or a refresh, must not replay the fanfare.
  const wasMine = useRef(isMyTurn)
  useEffect(() => {
    if (isMyTurn && !wasMine.current) playTurn()
    wasMine.current = isMyTurn
  }, [isMyTurn])

  const sang = useRef<Side | 'draw' | 'none' | null>(null)
  useEffect(() => {
    const won = state?.winner ?? null
    if (sang.current === null) { sang.current = won ?? 'none'; return }
    if (!won || sang.current === won) return
    sang.current = won
    // A stalemate draw (0051) is neither side's fanfare -- it plays no win
    // or lose cue at all rather than sounding like a loss for both players,
    // which `won === mySide` being false for a 'host'/'guest' mySide would
    // otherwise do.
    if (won === 'draw') return
    // A spectator has no side to lose with, so they get the flourish either
    // way rather than a defeat that is not theirs.
    if (mySide === null || won === mySide) playWin()
    else playLose()
  }, [state?.winner, mySide])

  /** Leave for another room. Deliberately not wrapped in guard(): guard
   *  refreshes when it is done, and refreshing the room you have just walked
   *  out of is what used to drop the old finished match back on top of the new
   *  one. */
  function goTo(next: string) {
    leaveMatch(matchId)
    onGoTo(next)
  }

  // ---------------------------------------------------------------------
  // Match end: RP swing, the advantage read, and "find another opponent".
  // ---------------------------------------------------------------------

  // The one match_results row finish_match() wrote for this match, if it
  // wrote one at all -- absent for a bot match, or a friend/tournament match
  // with the LP toggle off (see getMatchResult's own comment). Fetched once
  // per match, the moment a winner exists; match.code is unique per match
  // (rematches included), so there is nothing to disambiguate.
  useEffect(() => {
    if (!match?.winner || !match.code) return
    if (fetchedResultFor.current === match.id) return
    fetchedResultFor.current = match.id
    getMatchResult(match.code).then(setMatchResult)
  }, [match?.winner, match?.code, match?.id])

  // One sample per turn, from the moment deployment ends (nothing to measure
  // before both armies actually exist) to the moment the match does -- see
  // AdvantageChart.tsx for how `edge` is drawn. Scored relative to the
  // VIEWER (mySide, or 'host' for a spectator) so positive always reads as
  // "the person watching was ahead", the same way the board itself always
  // puts you at the bottom regardless of which literal side you are.
  useEffect(() => {
    const st = match?.state
    if (!st || match?.status === 'deploying') return
    if (!initialMaxHp.current) {
      const totalOf = (side: Side) =>
        st.units.filter((u) => u.owner === side).reduce((sum, u) => sum + u.maxHp, 0)
      const host = totalOf('host')
      const guest = totalOf('guest')
      if (host > 0 && guest > 0) initialMaxHp.current = { host, guest }
    }
    const base = initialMaxHp.current
    if (!base) return
    const near: Side = mySide ?? 'host'
    const far: Side = near === 'host' ? 'guest' : 'host'
    const scoreOf = (side: Side) => {
      const units = st.units.filter((u) => u.owner === side)
      const hp = units.reduce((sum, u) => sum + u.hp, 0)
      // HP is the headline; a unit actively burning, poisoned or stunned
      // right now costs its side a few points on top, since "ahead on
      // paper but everybody is on fire" is not really ahead.
      const penalty = units.reduce((sum, u) => sum + afflictionsOf(u).length, 0) * 3
      return Math.max(0, (100 * hp) / base[side] - penalty)
    }
    const edge = Math.max(-100, Math.min(100, scoreOf(near) - scoreOf(far)))
    const turn = st.turnNumber
    setAdvHistory((prev) => {
      if (prev.length > 0 && prev[prev.length - 1].turn === turn) {
        if (prev[prev.length - 1].edge === edge) return prev
        // Same turn as the last sample -- overwrite it rather than stack a
        // second point on one turn number. Covers the winning blow itself,
        // which lands mid-turn and deserves the FINAL score, not the one
        // from whenever this turn started.
        const next = prev.slice(0, -1)
        next.push({ turn, edge })
        return next
      }
      return [...prev, { turn, edge }]
    })
  }, [match?.state, match?.status, mySide])

  // Opens itself once, the instant a winner exists -- t(...), not
  // resultsOpen alone, gates the Modal below, so dismissing it (Escape, the
  // backdrop, the X) never has this effect silently reopening it on the
  // next poll.
  useEffect(() => {
    if (match?.winner && openedResultsFor.current !== match.id) {
      openedResultsFor.current = match.id
      setResultsOpen(true)
    }
  }, [match?.winner, match?.id])

  useEffect(() => {
    if (!findingNext) return
    let alive = true
    const tick = async () => {
      try {
        const q = await rankedTick()
        if (!alive) return
        setFindWaiting(q.waiting)
        if (q.match) { setFindingNext(false); goTo(q.match) }
      } catch (e) {
        if (alive) { setFindingNext(false); setErr((e as Error).message) }
      }
    }
    tick()
    const poll = setInterval(tick, 2000)
    const clock = setInterval(
      () => setFindElapsed(Math.floor((Date.now() - findSince.current) / 1000)), 500,
    )
    return () => { alive = false; clearInterval(poll); clearInterval(clock) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [findingNext])

  function findAnother() {
    findSince.current = Date.now()
    setFindElapsed(0)
    setFindingNext(true)
  }
  function cancelFindAnother() {
    setFindingNext(false)
    leaveRanked()
  }

  // Jared: "I was fighting with King Stelaris and tried to attack with it,
  // and there was no fight scene... sometimes when I move cards, they don't
  // do the animation... just choppy instant teleport." Traced to the same
  // root cause for both: NOTHING previously stopped a second onMove/
  // onAttack/onAbility/... from firing while the FIRST one's request was
  // still in flight -- `guard()` had no notion of "busy" at all. Two
  // requests landing that close together race the realtime/poll pipeline
  // in useMatch.ts (which only ever keeps the LATEST row, by design -- see
  // its own comment) into skipping the FIRST one's result entirely: this
  // component's board never renders the in-between state, so the fight
  // cinematic that exchange would have queued (Board.tsx's `[state]`
  // effect, keyed off `fx.seq` actually changing) never gets queued at
  // all, and Board's own move-tilt animation -- which deliberately gives up
  // and snaps units straight to place the moment more than two have moved
  // between two renders it actually saw, on the reasonable assumption that
  // that many at once means the board was replaced, not just quickly
  // played -- has exactly that "more than two changed at once" excuse
  // handed to it by the very same skipped render. Fixing how fast a player
  // (or a bot) can legally fire a SECOND action, rather than trying to make
  // either downstream effect smarter about ground it never actually saw,
  // is the fix that actually closes the gap: `busy` below blocks the board
  // for the entire round trip, not just from the moment a response lands.
  const [busy, setBusy] = useState(false)

  async function guard(fn: () => Promise<unknown>) {
    setErr(null)
    setBusy(true)
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

  // A match with no board is not a match yet. `matches.state` is `jsonb not
  // null`, so this cannot come from the database -- it can only come from a
  // row that arrived incomplete, which useMatch now refuses and refetches.
  // This is the second lock on the same door, and it is here because EVERY
  // line below assumes a board: a screen that renders its own loading state
  // for half a second is the correct answer to "the board has not arrived",
  // and a white page is not.
  if (!match || !match.state) {
    return (
      <div className="center-stage">
        <p className="muted">{t('match.loading')}</p>
      </div>
    )
  }

  const s = match.state

  // THE PINNED CARD IS THE ONE YOU CHOSE; THE OTHER IS THE ONE YOU ARE
  // POINTING AT.
  //
  // This used to be yours-left and theirs-right, which read well until a card
  // was pinned open: two of your own units then wanted the same edge and one
  // of them lost. Left and right now mean "picked" and "pointed at", which is
  // the comparison anybody with two cards open is actually making -- and it
  // also means a pinned card never moves, so it can be read while the pointer
  // goes wandering.
  //
  // .arena spans exactly the gap between the two rails, so an edge of it is
  // outside the board and still clear of the chat and the log.
  const board = shown ?? s
  const unitAt = (id: string | null) => (id ? board.units.find((u) => u.id === id) : undefined)
  const treeAt = (id: string | null) =>
    (id ? (board.obstacles ?? []).find((o) => o.id === id) : undefined)

  const pinnedUnit = unitAt(selected)
  const pinnedCard = pinnedUnit
    ? <UnitBigCard unit={pinnedUnit} side="left" pinned
                   swamped={isSwamped(board, pinnedUnit)} />
    : null

  // Hovering the one already pinned open opens nothing: it is on screen.
  const hoverId = hovered && hovered !== selected ? hovered : null
  const hoverUnit = unitAt(hoverId)
  const hoverTree = treeAt(hoverId)
  const hoverCard = hoverUnit
    ? <UnitBigCard unit={hoverUnit} side="right"
                   swamped={isSwamped(board, hoverUnit)} />
    : hoverTree ? <TreeBigCard tree={hoverTree} side="right" />
    : null

  // Opened by a long press and closed by the next tap anywhere else. The
  // scrim below is what catches that tap, which also keeps it off the board --
  // dismissing a card should never be the tap that moves a unit.
  const peekUnit = unitAt(peeked)
  const peekTree = treeAt(peeked)
  const peekCard = peekUnit
    ? <UnitBigCard unit={peekUnit} side="peek"
                   swamped={isSwamped(board, peekUnit)} />
    : peekTree ? <TreeBigCard tree={peekTree} side="peek" />
    : null

  const pct = remaining === null ? 0 : Math.max(0, Math.min(1, remaining / clockLength))
  const urgent = remaining !== null && remaining <= 8

  return (
    <div className="match">
      <header className="matchbar">
        <button
          className="linkbtn"
          onClick={() => {
            // Jared: "if a match is finished, and I want to go back to
            // lobby, I shouldn't see the pop-up of 'Are you sure?' since the
            // match is finished, obviously it's fine to leave." A finished
            // bot match has nothing left to lose by leaving early -- there is
            // no "early" left -- so the confirm is only for a bot match still
            // actually in progress.
            if (match.bot != null && match.status !== 'finished') setConfirmLobby(true)
            else leave()
          }}
        >
          {t('match.lobby')}
        </button>

        <div className="scoreline">
          <Nameplate
            name={match.host_name} side="host"
            active={s.turn === 'host' && match.status === 'active'} you={mySide === 'host'}
            color={nameColors[match.host_id]?.name_color}
          />
          <span className="vs">vs</span>
          <Nameplate
            name={match.guest_name ?? 'waiting…'}
            side="guest"
            active={s.turn === 'guest' && match.status === 'active'}
            you={mySide === 'guest'}
            color={match.guest_id ? nameColors[match.guest_id]?.name_color : null}
          />
        </div>

        <div className="matchbar-right">
          <button
            className="roomcode"
            title={t('match.copyCode')}
            onClick={() => navigator.clipboard?.writeText(match.code)}
          >
            {match.code}
          </button>
          {mySide === null && <span className="pill spectating">{t('match.watching')}</span>}
        </div>
      </header>

      {showGetReady && (
        <div className="getready" role="status">
          <p>{t('match.getReady')}</p>
        </div>
      )}

      {showVsIntro && (
        <VsIntro match={match} onDone={() => { introWanted.current = false; setShowVsIntro(false) }} />
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
              ? mySide
                ? t(iAmReady ? 'match.waitingForThem' : 'match.placeUnits')
                : t('match.bothDeploying')
              : botTurn
                ? t('match.thinking', { name: match.guest_name })
              : isMyTurn
                ? t('match.yourTurn')
                : mySide
                  ? t('match.opponentThinking')
                  : t('match.toAct', {
                      name: s.turn === 'host' ? match.host_name : match.guest_name,
                    })}
            {' · '}
            {Math.max(0, Math.ceil(remaining ?? 0))}s
          </div>

          {/* The two goes. Nothing on screen used to say how many were left,
              which made the server's refusal ("no actions left this turn") the
              first time you heard about the rule. The opening turn has one pip
              rather than two, because it really does have one activation. */}
          {match.status === 'active' && !s.winner && (
            <div
              className="goes"
              role="img"
              aria-label={t('match.goesLabel', {
                left: actsLeft, cap: actsCapNow,
                word: t(actsCapNow === 1 ? 'match.go' : 'match.goes'),
              })}
              title={t('match.goesLeft', { left: actsLeft, cap: actsCapNow })}
            >
              {Array.from({ length: actsCapNow }, (_, i) => (
                <span key={i} className={`go${i < actsSpent ? ' is-used' : ''}`} />
              ))}
            </div>
          )}
        </div>
      )}

      <div className="stage">
        <Chat
          matchId={match.id}
          profile={profile}
          messages={messages}
          role={mySide ? 'player' : 'spectator'}
          open={rail === 'chat'}
        />

        <main className="center">
          {match.status === 'waiting' ? (
            <div className="waiting">
              <p className="muted">{t('match.sendCode')}</p>
              <div className="bigcode">{match.code}</div>
              <button className="btn" onClick={() => navigator.clipboard?.writeText(match.code)}>
                {t('match.copyCodeBtn')}
              </button>
              {/* The last moment this can matter. join_match builds both
                  armies out of deck_of(), so the room is the final pre-battle
                  screen -- and the only one that is not in the menu. */}
              {mySide !== null && <KingdomSwitch profile={profile} onProfile={onProfile} />}
            </div>
          ) : (
            <>
              {/* The board's shape, on the arena as well as on the board.
                  The cards are the arena's children and the board is their
                  sibling, so this is the only way they can be sized from the
                  gap the board leaves rather than from a guess at it. */}
              <div
                className="arena"
                style={{ '--cols': s.board.w, '--rows': s.board.h } as React.CSSProperties}
              >
                {pinnedCard}
                {hoverCard}
                {peekCard && (
                  <div
                    className="peekscrim"
                    onPointerDown={() => setPeeked(null)}
                    aria-hidden="true"
                  />
                )}
                {peekCard}
                <Board
                  state={shown ?? s}
                  matchId={matchId}
                  mySide={mySide}
                  isMyTurn={isMyTurn}
                  deploying={Boolean(deploying && !iAmReady)}
                  selectedId={selected}
                  onSelect={setSelected}
                  onMove={(x, y) => selected && guard(() => submitMove(match.id, selected, x, y))}
                  onAttack={(target) => selected && guard(() => submitAttack(match.id, selected, target))}
                  onAbility={(unitId, target) =>
                    guard(() => submitAbility(match.id, unitId, target))}
                  onThrow={(target) => guard(() => submitThrow(match.id, target))}
                  onDefend={(unitId) => guard(() => submitDefend(match.id, unitId))}
                  onWait={() => guard(() => submitWait(match.id))}
                  onDeploy={(id, x, y) =>
                    guard(async () => setMyUnits(await deployUnit(match.id, id, x, y)))
                  }
                  onHover={setHovered}
                  onPeek={setPeeked}
                  ghost={ghost}
                  onLook={look}
                  onWatching={setWatching}
                  introOpen={showGetReady || showVsIntro}
                  locked={Boolean(turnBand) || busy}
                />
              </div>

              {/* Hover is how you read a card on a desktop, and phones do not
                  have it. Tapping already selects, so the selection doubles as
                  the way to inspect -- which helps on desktop too, since you
                  can read a unit while planning instead of only while pointing
                  at it. */}
              {selectedUnit ? (
                <div className="unitbar" style={{ '--accent': selectedUnit.accent } as React.CSSProperties}>
                  <span className="unitbar-name">{selectedUnit.name}</span>
                  <span className="unitbar-stats">
                    <b>{selectedUnit.hp}</b>/{selectedUnit.maxHp} {t('stat.hp')}
                    <i /><b>{unitPower(selectedUnit)}</b>{' '}
                    {t(selectedUnit.heals ? 'stat.pwr' : 'stat.dmg')}
                    <i /><b>{selectedUnit.mov}</b> {t('stat.mov')}
                    <i /><b>{reachText(selectedUnit.rmin, selectedUnit.rmax)}</b> {t('stat.rng')}
                  </span>
                  {/* The card row's sentence, not the snapshot's -- the
                      snapshot cannot hold a translation written after the
                      match began. Falls back to the snapshot for a slug that
                      is no longer in the roster. */}
                  <Ability
                    className="unitbar-ability"
                    text={abilityText(bySlug.get(selectedUnit.slug)) || selectedUnit.ability}
                  />
                </div>
              ) : (
                /* Mounted even when nothing is selected. If it came and went
                   with the selection it would resize the arena on every tap,
                   and the board would jump under your thumb. */
                <div className="unitbar is-empty">
                  <span className="unitbar-stats">{t('match.pickToRead')}</span>
                </div>
              )}

              {/* Three missed turns is a fact, not a verdict. The server will
                  only hand you the win once they have actually dropped -- or
                  after six -- so the button says what it will try and any
                  refusal is shown where it was clicked instead of vanishing. */}
              {theyAreAway && (
                <div className="awaybar">
                  <p>
                    {t('match.awayNotice', {
                      name: theirSide === 'host' ? match.host_name : match.guest_name,
                    })}
                  </p>
                  <button className="btn small" onClick={() => guard(() => claimWin(match.id))}>
                    {t('match.claimWin')}
                  </button>
                </div>
              )}

              <div className="actionbar">
                {s.winner ? (
                  <>
                    {/* The rich version of this -- RP swing, the advantage
                        read, rematch/find-another/lobby -- is the results
                        Modal below, which opens itself the instant a winner
                        exists. This strip is only what is left once it is
                        open (nothing, the board speaks for itself under a
                        dimmed backdrop) or once the player has dismissed it
                        and wants it back. */}
                    <div className="verdict">
                      {s.winner === 'draw' ? (
                        t('match.stalemateDraw')
                      ) : (
                        <>
                          {t('match.wins', {
                            name: (s.winner === 'host' ? match.host_name : match.guest_name) ?? '—',
                          })}
                          {s.winner === mySide ? t('match.winsYou') : '.'}
                        </>
                      )}
                    </div>
                    {!resultsOpen && (
                      <button className="btn primary" onClick={() => setResultsOpen(true)}>
                        {t('match.viewResults')}
                      </button>
                    )}
                  </>
                ) : deploying ? (
                  mySide ? (
                    <>
                      <button
                        className="btn primary"
                        disabled={iAmReady}
                        onClick={() => guard(() => setReady(match.id))}
                      >
                        {t(iAmReady ? 'match.waitingThem' : 'match.ready')}
                      </button>
                      <button
                        className="btn ghost"
                        onClick={() => (
                          match.ranked
                            ? setConfirmLeaveDeploy(true)
                            : guard(() => resignMatch(match.id))
                        )}
                      >
                        {t('common.leave')}
                      </button>
                      <span className="hint">
                        {t(iAmReady ? 'match.lockedIn' : 'match.deployHint')}
                      </span>
                      {/* Which five, and not where. See their_army() in 0026:
                          the phase stays blind about the thing it exists to
                          keep secret. */}
                      {theirs && theirs.length > 0 && (
                        <div className="theirs">
                          <span className="theirs-label">{t('match.theyBring')}</span>
                          {theirs.map((u) => (
                            <span key={u.id} className="theirs-one" title={u.name}>
                              <Avatar slug={u.slug} name={u.name} size={30} />
                              <b>{u.name}</b>
                            </span>
                          ))}
                        </div>
                      )}
                    </>
                  ) : (
                    <span className="hint">{t('match.bothPlacing')}</span>
                  )
                ) : mySide ? (
                  <>
                    <button className="btn primary" onClick={() => guard(() => endTurn(match.id))} disabled={!isMyTurn}>
                      {t('match.endTurn')}
                    </button>
                    <button className="btn ghost" onClick={() => setConfirmResign(true)}>
                      {t('match.resign')}
                    </button>
                    <span className="hint">
                      {!isMyTurn
                        ? t('match.waitingOpponent')
                        : actsLeft === 0
                          ? t('match.noGoesLeft')
                          : t('match.pickThenMenu', {
                              left: actsLeft, cap: actsCapNow,
                              word: t(actsCapNow === 1 ? 'match.go' : 'match.goes'),
                            })}
                    </span>
                  </>
                ) : (
                  <span className="hint">{t('match.spectating')}</span>
                )}
              </div>
            </>
          )}
          {/* Deliberately not a modal: no backdrop, nothing dimmed, nothing you are
          forced to answer before you can look at the board again. It sits over
          the middle, and if you ignore it the match screen is still yours. */}
      {challenged && (
        <div className="challenge" role="status">
          <p className="challenge-text">
            {t('match.challenge', {
              name: theirSide === 'host' ? match.host_name : match.guest_name,
            })}
          </p>
          <div className="challenge-acts">
            <button className="btn primary small" onClick={askRematch}>
              {t('match.challengeYes')}
            </button>
            <button
              className="btn small"
              onClick={() => guard(() => declineRematch(match.id))}
            >
              {t('match.challengeNo')}
            </button>
          </div>
        </div>
      )}

      {err && <div className="toast">{err}</div>}
        </main>

        <BattleLog log={s.log} open={rail === 'log'} />

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

      {/* Only reachable against a bot -- see confirmLobby's own comment.
          Leaving a human match needs no confirmation (nothing is lost that
          the sweep or a reconnect doesn't already cover); leaving a bot
          match ends it outright, which is the one case worth a click to
          undo. Same Modal/actionbar shape as Board.tsx's friendly-fire
          confirmation, so a player who has seen one has seen both. */}
      {confirmLobby && (
        <Modal title={t('match.confirmLobby')} onClose={() => setConfirmLobby(false)}>
          <div className="actionbar">
            <button className="btn ghost" onClick={() => setConfirmLobby(false)}>
              {t('common.cancel')}
            </button>
            <button className="btn danger" onClick={() => { setConfirmLobby(false); leave() }}>
              {t('match.confirmLobbyYes')}
            </button>
          </div>
        </Modal>
      )}

      {confirmResign && (
        <Modal title={t('match.confirmResign')} onClose={() => setConfirmResign(false)}>
          <div className="actionbar">
            <button className="btn ghost" onClick={() => setConfirmResign(false)}>
              {t('common.cancel')}
            </button>
            <button
              className="btn danger"
              onClick={() => { setConfirmResign(false); guard(() => resignMatch(match.id)) }}
            >
              {t('match.confirmResignYes')}
            </button>
          </div>
        </Modal>
      )}

      {/* Jared: leaving mid-deploy in a ranked match is not the free out it
          used to be everywhere else -- see confirmLeaveDeploy's own
          declaration for why. Same shape as confirmResign above, on
          purpose: a player who has seen one forfeit confirmation should
          recognise the other instantly. */}
      {confirmLeaveDeploy && (
        <Modal title={t('match.confirmLeaveDeploy')} onClose={() => setConfirmLeaveDeploy(false)}>
          <div className="actionbar">
            <button className="btn ghost" onClick={() => setConfirmLeaveDeploy(false)}>
              {t('common.cancel')}
            </button>
            <button
              className="btn danger"
              onClick={() => { setConfirmLeaveDeploy(false); guard(() => resignMatch(match.id)) }}
            >
              {t('common.leave')}
            </button>
          </div>
        </Modal>
      )}

      {/* The chess.com-style results popup -- opens itself the moment
          s.winner exists (see the effect above) and stays reachable
          afterwards through the "View results" button in the condensed
          strip once dismissed. */}
      {resultsOpen && s.winner && (() => {
        const myName = mySide === 'guest' ? match.guest_name : match.host_name
        const otherName = mySide === 'guest' ? match.host_name : match.guest_name
        const myDelta = !matchResult ? null
          : matchResult.winner_id === profile.id ? matchResult.winner_lp
          : matchResult.loser_id === profile.id ? matchResult.loser_lp
          : null
        const friendTarget = match.bot == null && theirSide
          && (theirSide === 'host' ? match.host_id : match.guest_id)
        return (
          <Modal
            title={s.winner === 'draw'
              ? t('match.stalemateDraw')
              : t('match.wins', {
                  name: (s.winner === 'host' ? match.host_name : match.guest_name) ?? '—',
                }) + (s.winner === mySide ? t('match.winsYou') : '')}
            onClose={() => setResultsOpen(false)}
          >
            <div className="matchend">
              {s.forfeitedBy && (
                <p className="matchend-note">
                  {t('match.forfeited', {
                    name: (s.forfeitedBy === 'host' ? match.host_name : match.guest_name) ?? '—',
                  })}
                </p>
              )}

              {myDelta !== null && (
                <div className={`matchend-rp ${myDelta >= 0 ? 'is-up' : 'is-down'}`}>
                  {t('match.rpChange', { n: myDelta >= 0 ? `+${myDelta}` : String(myDelta) })}
                </div>
              )}

              {advHistory.length >= 2 && (
                <AdvantageChart
                  points={advHistory}
                  youName={myName ?? t('match.you')}
                  themName={otherName ?? t('match.opponent')}
                />
              )}

              {friendTarget && (
                <AddFriendButton userId={profile.id} targetId={friendTarget as string} />
              )}

              <div className="matchend-actions">
                <button className="btn primary" disabled={iAsked} onClick={askRematch}>
                  {t(iAsked ? 'match.waitingThem' : 'match.rematch')}
                </button>
                {match.ranked && (
                  findingNext ? (
                    <button className="btn accent" onClick={cancelFindAnother}>
                      {t('match.findingAnother', { seconds: findElapsed, waiting: findWaiting })}
                    </button>
                  ) : (
                    <button className="btn accent" onClick={findAnother}>
                      {t('match.findAnother')}
                    </button>
                  )
                )}
                <button className="btn ghost" onClick={leave}>
                  {t('match.goToLobby')}
                </button>
              </div>
              {(match.bot != null || iAsked || match.rematch_declined) && (
                <span className="hint">
                  {match.bot != null
                    ? t('match.rematchBot')
                    : iAsked
                      ? t('match.rematchAsked')
                      : t('match.rematchDeclined')}
                </span>
              )}
            </div>
          </Modal>
        )
      })()}
    </div>
  )
}

function Nameplate({ name, side, active, you, color }: {
  name: string; side: Side; active: boolean; you: boolean; color?: string | null
}) {
  const t = useT()
  return (
    <span className={`nameplate ${side} ${active ? 'active' : ''}`} style={active ? undefined : nameColorStyle(color)}>
      {name}
      {you && <em>{t('match.you')}</em>}
    </span>
  )
}
