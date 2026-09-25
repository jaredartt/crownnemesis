import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  tournamentJoin, tournamentLeave, tournamentStartNow, tournamentTick,
} from '../lib/api'
import type { Profile, Tourney, TourneySlot } from '../lib/types'
import { useT } from '../lib/i18n'
import { Avatar } from './Avatar'
import { IconTrophy } from './Icons'

/**
 * The tournament page: the sign-up sheet, the countdown, and the bracket.
 *
 * IT DRAWS WHAT THE SERVER SAYS AND WORKS NOTHING OUT. Which round somebody is
 * in, who got a bye, whose match is whose and who is still waiting were all
 * decided in 0028 when the bracket locked. Re-deriving any of it here would be
 * a second implementation of the same rules, and two implementations of one
 * rule is one rule and one bug.
 *
 * THE TICK IS ALSO THE REFEREE, which is why this page polls while it is open
 * even for somebody who is only watching. A bracket cannot depend on the two
 * people in a match to push it along, because the case it has to survive is
 * exactly the one where both of them have gone. See 0028's header.
 */

/** Often enough that a countdown and a bracket feel live, slow enough that a
 *  page left open all evening is not a load. The countdown itself is drawn
 *  from the server's clock every second in between, so it never looks stuck
 *  between ticks. */
const TICK_MS = 3000

export function Tournament({ profile, onEnter }: {
  profile: Profile
  onEnter: (matchId: string) => void
}) {
  const t = useT()
  const [tour, setTour] = useState<Tourney | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [, redraw] = useState(0)

  /** The difference between this machine's clock and the server's. Every reply
   *  carries `now`, so a countdown is drawn against the clock that owns it --
   *  a player whose watch is two minutes fast should not see the bracket lock
   *  two minutes early and think it is broken. */
  const offset = useRef(0)

  const take = useCallback((next: Tourney | null) => {
    if (next) offset.current = Date.parse(next.now) - Date.now()
    setTour(next)
  }, [])

  useEffect(() => {
    let alive = true
    const beat = async () => {
      try {
        const next = await tournamentTick()
        if (alive) { take(next); setErr(null) }
      } catch (e) {
        if (alive) setErr((e as Error).message)
      }
    }
    void beat()
    const id = setInterval(beat, TICK_MS)
    return () => { alive = false; clearInterval(id) }
  }, [take])

  // The countdown's own second hand. Separate from the poll so the number
  // moves every second rather than every three.
  useEffect(() => {
    if (!tour?.locksAt) return
    const id = setInterval(() => redraw((n) => n + 1), 1000)
    return () => clearInterval(id)
  }, [tour?.locksAt])

  const act = useCallback(async (fn: () => Promise<Tourney | null>) => {
    setBusy(true); setErr(null)
    try { take(await fn()) } catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }, [take])

  const rounds = tour?.rounds ?? 0
  const byRound = useMemo(() => {
    const out: TourneySlot[][] = []
    for (const s of tour?.bracket ?? []) {
      ;(out[s.round - 1] ??= []).push(s)
    }
    return out.map((r) => r.sort((a, b) => a.slot - b.slot))
  }, [tour?.bracket])
  // Jared: "why is there a huge gap? ... make it look professional and
  // clean." The round with the most slots is always round 1 -- every later
  // round has half as many -- so THAT count is what .tr-bracket needs room
  // for. A flat height sized for a real bracket left a bracket of 2 (one
  // round, one slot) with a tall empty box and its lone match card
  // floating in the middle of it for no reason; this scales the floor down
  // for a small bracket and up for a large one instead of guessing one
  // number for both. 66px is a slot's own rough height plus a little air;
  // 120px is the least this should ever be, even for a single slot.
  const bracketMinHeight = Math.max(120, (byRound[0]?.length ?? 1) * 66)

  if (!tour) {
    return <p className="muted">{err ?? t('tourney.loading')}</p>
  }

  const live = tour.entries.filter((e) => !e.out)
  const secondsLeft = tour.locksAt
    ? Math.max(0, Math.round((Date.parse(tour.locksAt) - (Date.now() + offset.current)) / 1000))
    : null

  // Round names are written out one by one rather than built from a number,
  // because a constructed key is invisible to a search -- and this project has
  // shipped `settings.themeSystem` onto a screen once already for exactly that
  // reason. The last three rounds have names; anything before them is counted.
  const roundName = (r: number) =>
    r === rounds ? t('tourney.final')
    : r === rounds - 1 ? t('tourney.semi')
    : r === rounds - 2 ? t('tourney.quarter')
    : t('tourney.roundN', { n: r })

  const side = (id: string | null, name: string | null, slot: TourneySlot) => {
    const decided = slot.winnerId !== null
    const won = decided && slot.winnerId === id
    return (
      <span
        className={`tr-side${won ? ' is-won' : decided && id ? ' is-lost' : ''}${
          id === profile.id ? ' is-you' : ''}`}
      >
        {name ?? <i className="tr-tbd">{t('tourney.tbd')}</i>}
      </span>
    )
  }

  return (
    <div className="tourney">
      {/* ---- the standing of the whole thing, in one strip ---------------- */}
      {tour.status === 'open' && (
        <div className="tr-head">
          <div className="tr-headline">
            <strong>{t('tourney.signUps')}</strong>
            <span className="muted">
              {live.length === 1
                ? t('tourney.oneEntrant')
                : t('tourney.entrants', { n: live.length })}
            </span>
          </div>
          {/* Three is the whole lifecycle in one line: below it there is no
              clock, and saying so is better than an empty space where a
              countdown will one day be. */}
          <p className="tr-note">
            {secondsLeft === null
              ? t('tourney.needThree')
              : t('tourney.locksIn', { time: clock(secondsLeft) })}
          </p>
          <div className="tr-row">
            {tour.me.in ? (
              <button className="btn ghost" disabled={busy} onClick={() => act(tournamentLeave)}>
                {t('tourney.leaveSignUp')}
              </button>
            ) : (
              <button className="btn" disabled={busy} onClick={() => act(tournamentJoin)}>
                {t('tourney.join')}
              </button>
            )}
            {profile.is_admin && (
              <button
                className="btn small" disabled={busy || live.length < 2}
                onClick={() => act(tournamentStartNow)}
              >
                {t('tourney.startNow')}
              </button>
            )}
          </div>
        </div>
      )}

      {tour.status === 'running' && (
        <div className="tr-head">
          <div className="tr-headline">
            <strong>{t('tourney.underway')}</strong>
            <span className="muted">{t('tourney.ofN', { n: tour.size ?? 0 })}</span>
          </div>
          {/* WHERE YOU ARE, said plainly, because a bracket answers that only
              if you already know how to read one. */}
          <p className="tr-note">
            {tour.me.match ? t('tourney.yourMatchIsOn')
             : tour.me.out ? t('tourney.knockedOut')
             : tour.me.in ? t('tourney.waitingNext')
             : t('tourney.watchingOnly')}
          </p>
          <div className="tr-row">
            {tour.me.match && (
              <button className="btn" onClick={() => onEnter(tour.me.match!)}>
                {t('tourney.playYourMatch')}
              </button>
            )}
            {tour.me.in && !tour.me.out && (
              <button className="btn ghost small" disabled={busy} onClick={() => act(tournamentLeave)}>
                {t('tourney.forfeit')}
              </button>
            )}
          </div>
        </div>
      )}

      {tour.status === 'finished' && (
        <div className="tr-head tr-won">
          <div className="tr-headline">
            <strong>
              {tour.winnerId === profile.id
                ? t('tourney.youWon')
                : t('tourney.champion', { name: tour.winnerName ?? '' })}
            </strong>
          </div>
          <p className="tr-note">{t('tourney.nextOneIsOpen')}</p>
        </div>
      )}

      {/* ---- who is in, while there is no bracket to show yet ------------- */}
      {tour.status === 'open' && (
        <>
          <ul className="tr-entrants">
            {live.map((e) => (
              <li key={e.id} className={e.id === profile.id ? 'is-you' : ''}>
                <Avatar slug={e.avatar} name={e.name} size={26} />
                <span className="tr-name">{e.name}</span>
                <span className="num muted">{e.rating}</span>
              </li>
            ))}
          </ul>
          {/* Jared: drop the "nobody signed up yet" line, and put the
              rules blurb and the 4-player cup note on one line instead of
              two -- "at least 4 players should have participated" for the
              cup to count, said up front during sign-up rather than only
              discovered after the fact when the number does not move. */}
          <p className="muted tiny">{t('tourney.blurb')} {t('tourney.cupNeedsFour')}</p>
        </>
      )}

      {/* ---- the bracket -------------------------------------------------
          A column per round, each one holding half as many slots as the one
          before and spacing them out evenly -- which is what puts a match
          exactly between the two it is fed by, without a single computed
          coordinate. The bracket sizes itself to the entrant count because
          the server already did: 0028 writes every slot of every round when
          it locks, so this draws what is there. */}
      {byRound.length > 0 && (
        <div
          className="tr-bracket"
          style={{ '--rounds': rounds, minHeight: bracketMinHeight } as React.CSSProperties}
        >
          {byRound.map((slots, i) => {
            const isFinalRound = i + 1 === rounds
            return (
              <div className="tr-round" key={i}>
                {/* Jared: "where's the bracket UI with a cup in the middle?"
                    The copy already calls it that (tourney.blurb/champion/
                    youWon) -- this is the picture to go with the word.
                    Sits over the FINAL round specifically: that is where a
                    bracket actually converges, and for a bracket of 2 it is
                    the only round there is, so the cup lands right above
                    the one match that decides it instead of floating in an
                    otherwise empty box. */}
                {isFinalRound && (
                  <div className="tr-trophy" aria-hidden="true">
                    <IconTrophy />
                  </div>
                )}
                <h3 className="tr-roundname">{roundName(i + 1)}</h3>
                <div className="tr-slots">
                  {slots.map((s) => (
                    <div
                      key={s.id}
                      className={`tr-slot${s.bye ? ' is-bye' : ''}${
                        s.match && !s.winnerId ? ' is-live' : ''}`}
                    >
                      <div className="tr-pair">
                        {side(s.aId, s.aName, s)}
                        {side(s.bId, s.bName, s)}
                      </div>
                      <div className="tr-slotfoot">
                        {s.bye ? <span className="tr-tag">{t('tourney.bye')}</span>
                         : s.match && !s.winnerId ? (
                           /* Jared: "why is there two play buttons? It's
                              only two accounts that are going to play."
                              tour.me.match already has its own big, hard-
                              to-miss "Play your match" button in the head
                              strip above -- offering a second one here, on
                              the very slot that IS that match, was the
                              duplicate. Everybody else's live slot still
                              gets a Watch button, same as before. */
                           s.match === tour.me.match ? (
                             <span className="tr-tag tr-tag-live">{t('tourney.live')}</span>
                           ) : (
                             <button
                               className="btn tiny"
                               onClick={() => onEnter(s.match!)}
                             >
                               {t('common.watch')}
                             </button>
                           )
                         )
                         : s.winnerId ? <span className="tr-tag">{t('tourney.done')}</span>
                         : <span className="tr-tag muted">{t('tourney.waiting')}</span>}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )
          })}
        </div>
      )}

      {err && <p className="error">{err}</p>}
    </div>
  )
}

/** m:ss. Not a translated string: a clock reads the same in every language
 *  this app speaks, and running it through the dictionary would only give
 *  somebody the chance to translate the colon. */
function clock(seconds: number): string {
  const m = Math.floor(seconds / 60)
  const s = seconds % 60
  return `${m}:${String(s).padStart(2, '0')}`
}
