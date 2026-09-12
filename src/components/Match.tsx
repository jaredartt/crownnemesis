import { useEffect, useMemo, useRef, useState } from 'react'
import { Board } from './Board'
import { Chat } from './Chat'
import { BattleLog } from './BattleLog'
import { TreeBigCard, UnitBigCard } from './BigCard'
import { useMatch, useMessages, useServerClock } from '../lib/useMatch'
import { useGhost } from '../lib/useGhost'
import { isSwamped } from '../lib/swamp'
import {
  botStep, claimWin, declineRematch, deployUnit, endTurn, forceTimeout, leaveMatch,
  myDeploy, requestRematch, resignMatch, setReady, submitAbility, submitAttack, submitDefend, submitMove,
  submitThrow, submitWait, theirArmy,
} from '../lib/api'
import {
  DEPLOY_SECONDS, TURN_SECONDS, actsCap, reachText,
  type MatchState, type Profile, type Side, type Unit,
  unitPower,
} from '../lib/types'
import { abilityText, useT } from '../lib/i18n'
import { Ability } from './Ability'
import { Avatar } from './Avatar'
import { KingdomSwitch } from './KingdomSwitch'
import { useCardsBySlug } from '../lib/useCards'
import { playLose, playTurn, playWin } from '../lib/sfx'

/** How long "Defeat the king." holds the screen. Short on purpose: it is paid
 *  for out of a thirty-second first turn, and any key or tap takes it back. */
const PROCLAIM_MS = 2000

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
  const [proclaim, setProclaim] = useState(false)
  const opened = useRef<string | null>(null)
  const firedFor = useRef<string>('')

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 200)
    return () => clearInterval(id)
  }, [])

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
  const botTurn = Boolean(
    match?.bot != null && match.status === 'active' && state?.turn === 'guest'
    && !state?.winner && !watching,
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

  // "Defeat the king." Once per match, at the moment it becomes one.
  //
  // It costs about two seconds of a thirty-second first turn, which is a real
  // cost and the reason it is short and dismissed by any key or click. The
  // alternative -- pushing the deadline for it, the way 0021 pays for the
  // cinematic -- would be a migration and a round trip to buy back two seconds
  // that a player can take back themselves by tapping.
  useEffect(() => {
    if (!matchId || match?.status !== 'active') return
    if (opened.current === matchId) return
    opened.current = matchId
    // Only for a match watched from the start. Walking into one already in
    // progress and being told to defeat the king is a title card for a film
    // that is half over.
    if ((state?.turnNumber ?? 1) <= 1 && !state?.winner) setProclaim(true)
  }, [matchId, match?.status, state?.turnNumber, state?.winner])

  useEffect(() => {
    if (!proclaim) return
    const away = () => setProclaim(false)
    const id = setTimeout(away, PROCLAIM_MS)
    window.addEventListener('keydown', away)
    return () => { clearTimeout(id); window.removeEventListener('keydown', away) }
  }, [proclaim])

  // The bot plays one action per call, on a delay, so you watch it think
  // instead of finding its whole turn already done. Every step is a fresh
  // decision made by the server against the board as it now stands -- there is
  // no plan held anywhere on this side. `updated_at` changing is what schedules
  // the next one, so the chain stops on its own the moment the turn flips back.
  useEffect(() => {
    if (!botTurn || !match) return
    const id = setTimeout(() => botStep(match.id).then(refresh), 650)
    return () => clearTimeout(id)
  }, [botTurn, match?.id, match?.updated_at, refresh])

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

  const sang = useRef<Side | 'none' | null>(null)
  useEffect(() => {
    const won = state?.winner ?? null
    if (sang.current === null) { sang.current = won ?? 'none'; return }
    if (!won || sang.current === won) return
    sang.current = won
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

  async function guard(fn: () => Promise<unknown>) {
    setErr(null)
    try {
      await fn()
      await refresh()
    } catch (e) {
      setErr((e as Error).message)
      await refresh()
      setTimeout(() => setErr(null), 3500)
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
        <button className="linkbtn" onClick={leave}>
          {t('match.lobby')}
        </button>

        <div className="scoreline">
          <Nameplate name={match.host_name} side="host" active={s.turn === 'host' && match.status === 'active'} you={mySide === 'host'} />
          <span className="vs">vs</span>
          <Nameplate
            name={match.guest_name ?? 'waiting…'}
            side="guest"
            active={s.turn === 'guest' && match.status === 'active'}
            you={mySide === 'guest'}
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

      {proclaim && (
        <div
          className="proclaim"
          onPointerDown={() => setProclaim(false)}
          role="status"
        >
          <p>{t('match.defeatTheKing')}</p>
        </div>
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
                    <div className="verdict">
                      {t('match.wins', {
                        name: (s.winner === 'host' ? match.host_name : match.guest_name) ?? '—',
                      })}
                      {s.winner === mySide ? t('match.winsYou') : '.'}
                    </div>
                    <button className="btn primary" disabled={iAsked} onClick={askRematch}>
                      {t(iAsked ? 'match.waitingThem' : 'match.rematch')}
                    </button>
                    <span className="hint">
                      {match.bot != null
                        ? t('match.rematchBot')
                        : iAsked
                          ? t('match.rematchAsked')
                          : match.rematch_declined
                            ? t('match.rematchDeclined')
                            : t('match.rematchBoth')}
                    </span>
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
                      <button className="btn ghost" onClick={() => guard(() => resignMatch(match.id))}>
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
                    <button className="btn ghost" onClick={() => guard(() => resignMatch(match.id))}>
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
    </div>
  )
}

function Nameplate({ name, side, active, you }: { name: string; side: Side; active: boolean; you: boolean }) {
  const t = useT()
  return (
    <span className={`nameplate ${side} ${active ? 'active' : ''}`}>
      {name}
      {you && <em>{t('match.you')}</em>}
    </span>
  )
}
