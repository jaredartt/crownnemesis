import { useLayoutEffect, useRef, useState } from 'react'
import { isBurning, isPoisoned, isStunned } from '../lib/effects'
import type { Obstacle, Unit } from '../lib/types'
import { reachText, unitPower } from '../lib/types'
import { artUrl } from '../lib/art'
import { abilityText, useClassName, useT } from '../lib/i18n'
import { lessMotion } from '../lib/settings'
import { Ability } from './Ability'
import { useCardsBySlug } from '../lib/useCards'

/**
 * Where the card opens.
 *
 * 'left' is the PINNED one -- the unit you have selected, held open so you can
 * read it while pointing at something else. 'right' is whatever is under the
 * pointer. 'peek' is the phone: no pointer to hover with, so a long press puts
 * one card in the middle of the screen for as long as the finger is down.
 *
 * Pinned-left and hovered-right rather than yours-left and theirs-right, which
 * is what this was before ten kingdoms' worth of cards ago. The old rule read
 * well until a card was pinned, and then two of your own units wanted the same
 * edge and one of them lost. Left and right now mean "the one you chose" and
 * "the one you are pointing at", which is exactly the comparison anybody
 * opening two cards is trying to make.
 */
export type CardSide = 'left' | 'right' | 'peek'

/** The three slashes from the mark, small enough to read as a bullet. */
function Mark() {
  return (
    <svg className="bc-mark" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M8.6 3 2.6 21h3.6L12.2 3Z" />
      <path d="M14.2 3 8.2 21h3.6L17.8 3Z" />
      <path d="M19.8 3 13.8 21h3.6L23.4 3Z" />
    </svg>
  )
}

/**
 * A name is never truncated -- it is shrunk until it fits.
 *
 * "Dione & Grifo" is twice the width of "Fey" and has to sit beside a block
 * wide enough for 120/120, so no single font size works for both. An ellipsis
 * is the wrong answer for the one place a character's name is written out, so
 * this steps the size down until the text stops overflowing. The card mounts
 * fresh on every hover, so this runs once per card and measures one element.
 */
function FitName({ children }: { children: string }) {
  const ref = useRef<HTMLHeadingElement>(null)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    let k = 1
    el.style.setProperty('--fit', '1')
    while (el.scrollWidth > el.clientWidth + 0.5 && k > 0.56) {
      k -= 0.04
      el.style.setProperty('--fit', k.toFixed(2))
    }
  })
  return <h3 ref={ref} className="bc-name">{children}</h3>
}

/** How far a pinned card leans when you point at it, in degrees. Small: this
 *  is an object catching the light, not a thing being turned over. */
const TILT = 7

/**
 * The chrome, the motion, and nothing about what is on the card.
 *
 * A PINNED card drifts -- a slow rise and fall with a little roll in it, on a
 * nine-second loop so it never syncs with anything else on screen. Pointing at
 * it settles it into a tilt picked at random, so the same card caught twice
 * does not look like a still frame. Clicking it stops all of that and leaves it
 * flat, and clicking again lets it go; a card you are reading carefully should
 * be a card that holds still when you ask it to.
 *
 * The float is on an inner element and the tilt is on the outer one, which is
 * the only arrangement where both work: an animation's transform beats a
 * transition on the same element, so a tilt applied to the floating element
 * would jump between frames instead of easing.
 */
function Shell({ side, pinned, accent, tone, children }: {
  side: CardSide
  pinned?: boolean
  accent?: string
  tone?: string
  children: React.ReactNode
}) {
  const [still, setStill] = useState(false)
  const [tilt, setTilt] = useState<{ x: number; y: number } | null>(null)
  const quiet = lessMotion()

  const lean = () => {
    if (still || quiet) return
    const r = (n: number) => (Math.random() * 2 - 1) * n
    setTilt({ x: r(TILT), y: r(TILT) })
  }

  return (
    <aside
      className={[
        'bigcard', `bigcard-${side}`,
        pinned ? 'is-pinned' : '',
        pinned && (still || quiet) ? 'is-still' : '',
        tone ?? '',
      ].join(' ').trim()}
      style={{
        '--accent': accent,
        '--ptx': `${tilt ? -tilt.x : 0}deg`,
        '--pty': `${tilt ? tilt.y : 0}deg`,
      } as React.CSSProperties}
      onMouseEnter={pinned ? lean : undefined}
      onMouseLeave={pinned ? () => setTilt(null) : undefined}
      onClick={pinned ? () => { setStill((s) => !s); setTilt(null) } : undefined}
    >
      <div className="bc-box">{children}</div>
    </aside>
  )
}

/**
 * The card as it would be printed, with the illustration LEFT ALONE.
 *
 * Everything used to be cut into the picture -- the name on a band across the
 * top corner, the numbers and the rules text over the bottom third -- and the
 * budget for that was "how much of the art is hidden", which was about half.
 * Nothing is cut into it now: a header above, the square illustration, and two
 * strips below. The card is taller than it is wide as a result, and that is the
 * point. This is the only place in the whole app where the whole drawing is
 * visible, and a strip of type over somebody's face is a strange thing to
 * spend it on when there is room underneath.
 *
 * The rules text can be three lines now rather than two, because it is no
 * longer paying for itself in picture.
 */
export function UnitBigCard({ unit, side, pinned, swamped }: {
  unit: Unit
  side: CardSide
  pinned?: boolean
  /** Standing next to somebody's Umiro. Positional rather than a field on the
   *  unit, so whoever has the board in hand works it out and passes it in. */
  swamped?: boolean
}) {
  const t = useT()
  const className = useClassName()
  const bySlug = useCardsBySlug()
  const say = abilityText(bySlug.get(unit.slug)) || unit.ability
  return (
    <Shell
      side={side} pinned={pinned} accent={unit.accent}
      tone={unit.owner === 'host' ? 'unit-host' : 'unit-guest'}
    >
      <div className="bc-top">
        <div className="bc-id">
          <FitName>{unit.name}</FitName>
          {unit.role && <p>{className(unit.role)}</p>}
        </div>
        <div className="bc-hp"><b>{unit.hp}</b><i>/{unit.maxHp}</i></div>
      </div>

      <div className="bc-artwrap">
        {unit.art && <img className="bc-art" src={artUrl(unit.art)!} alt="" />}
      </div>

      <div className="bc-bottom">
        <div className="bc-stats">
          <span><em>{t(unit.heals ? 'stat.pwr' : 'stat.dmg')}</em><b>{unitPower(unit)}</b></span>
          <span><em>{t('stat.mov')}</em><b>{unit.mov}</b></span>
          <span><em>{t('stat.rng')}</em><b>{reachText(unit.rmin, unit.rmax)}</b></span>
          {/* Afflictions, in the same order the board draws them. Literal
              keys, one branch each -- see markTitle in Board.tsx. */}
          {isBurning(unit) && <span className="bc-burn"><b>{t('card.burning')}</b></span>}
          {isPoisoned(unit) && <span className="bc-poison"><b>{t('card.poisoned')}</b></span>}
          {isStunned(unit) && <span className="bc-stun"><b>{t('card.stunned')}</b></span>}
          {swamped && <span className="bc-swamp"><b>{t('card.swamped')}</b></span>}
        </div>
        {/* The card row's sentence where there is one, the snapshot's
            otherwise -- same rule as the strip under the board. */}
        {say && (
          <div className="bc-say">
            <span className="bc-glyph"><Mark /></span>
            <p><Ability text={say} /></p>
          </div>
        )}
      </div>
    </Shell>
  )
}

/** A tree gets the same card. It has health and a rule, which is all a card
 *  is for -- and it is the only way to learn a tree is worth 30 before you
 *  have hit one. */
export function TreeBigCard({ tree, side }: { tree: Obstacle; side: CardSide }) {
  const t = useT()
  return (
    <Shell side={side} tone="bigcard-tree">
      <div className="bc-top">
        <div className="bc-id"><FitName>{t('tree.name')}</FitName><p>{t('tree.role')}</p></div>
        <div className="bc-hp"><b>{tree.hp}</b><i>/{tree.maxHp}</i></div>
      </div>
      <div className="bc-artwrap">
        <img className="bc-art" src={`${import.meta.env.BASE_URL}tree.webp`} alt="" />
      </div>
      <div className="bc-bottom">
        <div className="bc-stats">
          <span><em>{t('tree.blocks')}</em><b>{t('tree.blocksWhat')}</b></span>
        </div>
        <div className="bc-say">
          <span className="bc-glyph"><Mark /></span>
          <p><Ability text={t('tree.note')} /></p>
        </div>
      </div>
    </Shell>
  )
}
