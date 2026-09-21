import { useCallback, useEffect, useRef, useState } from 'react'
import { HitBurst } from './HitBurst'
import { artUrl, faceUrl } from '../lib/art'
import { HITSTOP_MS, LEAD_MS, type Beat, type Cine, type Fighter } from '../lib/cine'
import { useT } from '../lib/i18n'
import {
  playBurn, playChop, playCounter, playDown, playHit, playMend, playParry,
} from '../lib/sfx'
import { playCardSound } from '../lib/customAudio'
import { useCardsBySlug } from '../lib/useCards'
import type { Card } from '../lib/types'

/**
 * The battle cinematic.
 *
 * Fire Emblem's shape: the board goes away, the two of them fill the screen,
 * and the exchange the server already decided is played back one beat at a
 * time with a caption saying what happened and which rule made it happen.
 * Nothing here decides anything -- cine.ts turned the server's record into a
 * timeline and this walks it.
 *
 * The turn clock is paid for. 0021 pushes the deadline by exactly cineMs(), so
 * watching this costs the player nothing, which is the only reason it is
 * allowed to take the screen at all. Lengthen a beat here without lengthening
 * cn_cine_ms() there and you start charging people to watch it.
 *
 * ---------------------------------------------------------------------------
 * Why almost nothing in here is a CSS animation on a class
 *
 * A CSS animation starts when its class arrives. If the class is already
 * there, it does not restart -- and consecutive beats of the same kind are the
 * normal case, not the edge one: a parry chain is eight parries in a row, and
 * two blows in a row is most fights. Driven by a class, the second one would
 * play nothing at all.
 *
 * So the lunge, the fall and the camera shake go through the Web Animations
 * API, which restarts on demand, and the flash, the ring and the damage number
 * are keyed by the beat so React hands each one a fresh element. The board's
 * FLIP animation is driven the same way for the same reason.
 * ------------------------------------------------------------------------- */
export function Duel({ cine, mySide, onDone }: {
  cine: Cine
  mySide: 'host' | 'guest' | null
  onDone: () => void
}) {
  const t = useT()
  const [i, setI] = useState(-1)          // -1 is the lead-in: squaring up
  const [stop, setStop] = useState(false) // hitstop, the freeze on contact
  const timers = useRef<ReturnType<typeof setTimeout>[]>([])
  const done = useRef(false)
  const root = useRef<HTMLDivElement | null>(null)
  // Since 0040. Not read by anything that decides what happens -- only by the
  // sound layer below, to find a card's own attack/ability/passive clip (if
  // it uploaded one) for the unit each swing names as `by`.
  const bySlug = useCardsBySlug()

  // onDone is held in a ref and kept OUT of the schedule's dependencies. If it
  // were in them, a fresh arrow from the parent on any re-render would tear
  // down every timer and start the cinematic again from the top -- the
  // blank-rematch-page bug wearing a different hat, and that one took a day to
  // find. The parent's callback is stable too; this is the second lock.
  const finish = useRef(onDone)
  finish.current = onDone

  // Everything is scheduled up front against one clock rather than each beat
  // arming the next. A chain of timeouts drifts, and worse, it drifts APART
  // from the sounds -- the failure that reads as broken even when the picture
  // is right. Hitstop lives inside a beat, so it costs no clock and cannot
  // accumulate.
  useEffect(() => {
    const fire = (f: () => void, ms: number) => { timers.current.push(setTimeout(f, ms)) }

    // Since 0040. `by` on a swing is always a unit -- the striker, the
    // healer, the parrier, the one who burned or fell -- so it is the one
    // consistent way to ask "whose card, if any, uploaded a sound for this
    // beat". Layered on top of the synthesised call already scheduled for
    // the same beat below, never in place of it; see customAudio.ts.
    const cardFor = (unitId: string): Card | null => {
      const slug = unitId === cine.a.id ? cine.a.slug : unitId === cine.b.id ? cine.b.slug : null
      return slug ? bySlug.get(slug) ?? null : null
    }

    cine.beats.forEach((b, n) => {
      fire(() => {
        setI(n)
        setStop(true)
        fire(() => setStop(false), HITSTOP_MS)
      }, b.at)
      const power = (v: number) => v / 28
      const s = b.swing
      const card = cardFor(s.by)
      if (s.k === 'hit') {
        fire(() => {
          if (s.why === 'tree') playChop(0)
          else if (s.counter) playCounter(power(s.dmg ?? 0), 0)
          else playHit(power(s.dmg ?? 0), 0)
          // An ability that lands as a 'hit' (0033's line_burn, aoe_adjacent
          // and so on) sounds like the card's ABILITY clip; every other hit
          // -- a plain strike, a counter, a crit, Himanta's second swing --
          // is the card's ATTACK clip. Not played for a tree: there is no
          // card behind it to have uploaded one.
          if (s.why !== 'tree') playCardSound(card, s.why === 'ability' ? 'ability' : 'attack')
        }, b.at)
      } else if (s.k === 'parry') {
        fire(() => { playParry(0.6, 0); playCardSound(card, 'passive') }, b.at)
      } else if (s.k === 'heal') {
        fire(() => { playMend(0); playCardSound(card, 'ability') }, b.at)
      } else if (s.k === 'burn') {
        fire(() => { playBurn(0); playCardSound(card, 'passive') }, b.at)
      } else if (s.k === 'down') fire(() => playDown(0), b.at)
    })

    fire(() => { if (!done.current) { done.current = true; finish.current() } }, cine.ms)
    return () => { timers.current.forEach(clearTimeout); timers.current = [] }
  }, [cine])

  const skip = useCallback(() => {
    if (done.current) return
    done.current = true
    timers.current.forEach(clearTimeout)
    timers.current = []
    finish.current()
  }, [])

  useEffect(() => {
    window.addEventListener('keydown', skip)
    return () => window.removeEventListener('keydown', skip)
  }, [skip])

  const beat: Beat | null = i >= 0 ? cine.beats[i] ?? null : null

  // Jared: "are you sure critical hits ever happen? ... add some epic and
  // camera shake animations when a critical hit happens." They do (5-10%
  // per swing, by card -- rare enough that a single ordinary-looking shake
  // read as nothing in particular), so this is a bigger, longer, rougher
  // version of the SAME shake beat -- not a second mechanism -- for a crit
  // specifically, so the one time in twenty actually reads as one.
  const isCrit = beat?.swing.k === 'hit' && Boolean(beat.swing.crit)

  useEffect(() => {
    if (!beat?.shake || !root.current || still()) return
    root.current.animate(
      isCrit
        ? [{ transform: 'translate(0,0) rotate(0)' },
           { transform: 'translate(-17px,10px) rotate(-1.1deg)' },
           { transform: 'translate(15px,-12px) rotate(1.1deg)' },
           { transform: 'translate(-12px,8px) rotate(-0.6deg)' },
           { transform: 'translate(9px,-6px) rotate(0.5deg)' },
           { transform: 'translate(-4px,3px)' },
           { transform: 'translate(0,0)' }]
        : [{ transform: 'translate(0,0)' }, { transform: 'translate(-7px,3px)' },
           { transform: 'translate(6px,-4px)' }, { transform: 'translate(-4px,2px)' },
           { transform: 'translate(0,0)' }],
      { duration: isCrit ? 380 : 220, easing: 'cubic-bezier(0.36, 0.07, 0.19, 0.97)' },
    )
  }, [beat, isCrit])

  // Before the first beat, both of them stand at what they came in with.
  const aHp = beat ? beat.aHp : cine.a.hp
  const bHp = beat ? beat.bHp : cine.b.hp

  // Yours on the left, theirs on the right -- the rule the hover card already
  // follows, so the screen never asks you which one you are. A spectator gets
  // the host on the left, the order the scoreline uses.
  const mine = mySide ?? 'host'
  const sides: ('a' | 'b')[] = cine.a.side === mine ? ['a', 'b'] : ['b', 'a']
  const hp = { a: aHp, b: bHp }

  return (
    <div
      ref={root}
      className={`duel${stop ? ' is-stopped' : ''}${i < 0 ? ' is-opening' : ''}`}
      role="dialog"
      aria-live="polite"
      aria-label={t('duel.title')}
      onClick={skip}
    >
      <div className="duel-ring" aria-hidden="true" />

      {/* The screen's own reaction to a crit, not one panel's -- same
          reasoning as the camera shake above, which is why this sits at the
          cinematic's own root rather than inside Panel. Keyed by beat.at so a
          second crit later in the same chain gets a fresh element and
          actually flashes again, the same trick .duel-flash's own comment
          already uses for a parry. */}
      {isCrit && <div key={`critflash${beat!.at}`} className="duel-crit-flash" aria-hidden="true" />}

      <div className="duel-pair">
        {sides.map((k, n) => {
          const f: Fighter = k === 'a' ? cine.a : cine.b
          const acting = beat?.actor === k
          return (
            <Panel
              key={f.id}
              fighter={f}
              hp={hp[k]}
              facing={n === 0 ? 'right' : 'left'}
              beat={beat}
              lunging={acting && beat?.swing.k === 'hit'}
              parrying={acting && beat?.swing.k === 'parry'}
              falling={beat?.swing.k === 'down' && beat.swing.by === f.id}
              pop={beat && beat.popAt === k && beat.pop > 0 ? beat : null}
              // The rhombuses go on whoever is TAKING the blow, and only for
              // a blow that took something off -- a mend and a miss get
              // nothing. The board fires its own burst at the same moment,
              // which is what a player sees with the takeover switched off;
              // this is the one they see with it on.
              burst={beat && beat.popAt === k && beat.pop > 0
                     && beat.popKind === 'dmg' ? beat.at : 0}
            />
          )
        })}
      </div>

      {/* The caption. Black box, white type, and the rule on a second line in
          the colour the keyword tooltips will use in Phase D -- so the two read
          as one voice when they meet. */}
      <div className={`duel-say${beat ? ' is-on' : ''}`}>
        {beat && (
          <>
            <p className="duel-text">{beat.text}</p>
            {beat.note && <p className="duel-note">{beat.note}</p>}
          </>
        )}
      </div>

      <button className="duel-skip" onClick={skip}>{t('duel.skip')}</button>
    </div>
  )
}

/** Whether to hold still: the system asked, or the player did in Settings. */
function still(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches
    || document.documentElement.dataset.reduceMotion === '1'
}

function Panel({ fighter, hp, facing, beat, lunging, parrying, falling, pop, burst }: {
  fighter: Fighter
  hp: number
  facing: 'left' | 'right'
  beat: Beat | null
  lunging: boolean
  parrying: boolean
  falling: boolean
  pop: Beat | null
  /** Non-zero and CHANGING per beat, so React remounts the burst instead of
   *  leaving a finished animation on screen. See HitBurst. */
  burst: number
}) {
  const pct = Math.max(0, Math.min(100, (hp / fighter.maxHp) * 100))
  const figure = useRef<HTMLDivElement | null>(null)
  // `at` is unique per beat within one cinematic, which makes it the natural
  // identity for "this beat's transient things".
  const tick = beat ? beat.at : -1

  useEffect(() => {
    const el = figure.current
    if (!el || still()) return
    if (falling) {
      el.animate(
        [{ opacity: 1, transform: 'translateY(0) rotate(0) scale(1)' },
         { opacity: 0, transform: 'translateY(40px) rotate(-12deg) scale(0.86)' }],
        { duration: 700, easing: 'ease-in', fill: 'forwards' },
      )
      return
    }
    if (!lunging) return
    // Toward the middle, which is where the other one is standing.
    const to = facing === 'right' ? 'clamp(20px, 5vw, 64px)' : 'clamp(-64px, -5vw, -20px)'
    const spin = facing === 'right' ? '3deg' : '-3deg'
    el.animate(
      [{ transform: 'translateX(0)' },
       { transform: `translateX(${to}) rotate(${spin})`, offset: 0.38 },
       { transform: 'translateX(0)' }],
      { duration: 420, easing: 'ease-out' },
    )
  }, [tick, lunging, falling, facing])

  return (
    <div
      className={[
        'duel-side',
        `is-facing-${facing}`,
        fighter.side === 'host' ? 'is-host' : fighter.side === 'guest' ? 'is-guest' : 'is-wood',
        lunging ? 'is-lunging' : '',
        parrying ? 'is-parrying' : '',
        falling ? 'is-falling' : '',
      ].join(' ')}
      style={{ '--accent': fighter.accent } as React.CSSProperties}
    >
      {burst > 0 && <HitBurst key={burst} />}
      <div className="duel-figure" ref={figure}>
        <div className="duel-art">
          {fighter.art
            ? <img src={faceUrl(fighter.art)!} alt=""
                   onError={(e) => {
                     const el = e.currentTarget
                     const full = artUrl(fighter.art)
                     if (full && el.src !== full) el.src = full
                   }} />
            : <span className="duel-initial">{fighter.name[0]}</span>}
        </div>
        {/* Smash Ultimate's parry, near enough: a hard white frame on the
            moment it is caught, and a ring thrown off it. Keyed by the beat so
            the second parry of a chain gets its own element and plays -- the
            same one handed new props would sit there having already run. */}
        {parrying && <div key={`f${tick}`} className="duel-flash" aria-hidden="true" />}
        {parrying && <div key={`r${tick}`} className="duel-ripple" aria-hidden="true" />}
        {pop && (
          <div
            key={`p${tick}`}
            className={`duel-pop is-${pop.popKind}${pop.swing.k === 'hit' && pop.swing.crit ? ' is-crit' : ''}`}
          >
            {pop.popKind === 'heal' ? '+' : '−'}{pop.pop}
          </div>
        )}
      </div>

      <div className="duel-name">{fighter.name}</div>
      <div className="duel-hp">
        <span className="duel-hpfill" style={{ width: `${pct}%` }} />
        <b>{hp}</b>
      </div>
    </div>
  )
}

/** The opening hold, exported so a test can wait it out rather than guess at
 *  it. The value itself belongs to cine.ts. */
export const DUEL_LEAD_MS = LEAD_MS
