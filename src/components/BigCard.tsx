import { useLayoutEffect, useRef, useState } from 'react'
import { afflictionsOf, MARK_ART, type Mark } from '../lib/effects'
import type { Card, Obstacle, Unit } from '../lib/types'
import { reachText, unitPower } from '../lib/types'
import { artUrl } from '../lib/art'
import { abilityText, currentLang, useClassName, useT } from '../lib/i18n'
import { lessMotion } from '../lib/settings'
import { Ability } from './Ability'
import { useCardsBySlug } from '../lib/useCards'
import { objKind } from '../lib/objects'
import { useStructuresBySlug } from '../lib/useStructures'
import { fighterInfoFor, ThingGlyph } from './Board'

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

/** A plain white rhombus, small enough to read as a bullet. Replaces the
 *  old three-slash mark. Named RulesMark, not Mark, so it does not collide
 *  with the Mark TYPE (burn/poison/stun/swamp) imported from lib/effects
 *  for the new effects panel below. */
function RulesMark() {
  return (
    <svg className="bc-mark" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 2 22 12 12 22 2 12Z" />
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
  // Same list Board.tsx's own (now-deleted) unit-marks row used to build --
  // swamp is positional rather than a field on the unit, so it is passed in
  // by whoever has the board in hand rather than read off `unit` itself.
  const marks: Mark[] = [...afflictionsOf(unit), ...(swamped ? ['swamp' as const] : [])]
  return (
    <Shell
      side={side} pinned={pinned} accent={unit.accent}
      // The chrome used to read the OWNER (host blue / guest red), which is
      // why every card looked the same colour no matter what was on it. It
      // reads the class now -- see the .bigcard.role-* rules in styles.css --
      // so a Royal card is orange and a Mage's is purple, same as the board's
      // own hover/select ring.
      tone={`${unit.owner === 'host' ? 'unit-host' : 'unit-guest'}${unit.role ? ` role-${unit.role}` : ''}`}
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
        </div>
        {/* Jared: "if a card has a status... add it as a box right next to
            the hovered/clicked/long-pressed card, saying all the effects
            they have, with their respective icon, and a short description".
            This card already opens on every one of those three, so the box
            is here rather than a second popup -- one icon, one short label,
            one sentence per active mark, guard included (it never had a
            badge here before at all). */}
        {(unit.defending || marks.length > 0) && (
          <div className="bc-effects">
            {unit.defending && <Effect mark="guard" t={t} />}
            {marks.map((m) => <Effect key={m} mark={m} t={t} />)}
          </div>
        )}
        {/* The card row's sentence where there is one, the snapshot's
            otherwise -- same rule as the strip under the board. */}
        {say && (
          <div className="bc-say">
            <span className="bc-glyph"><RulesMark /></span>
            <p><Ability text={say} /></p>
          </div>
        )}
      </div>
    </Shell>
  )
}

/** One row of the effects panel above: icon, short label, and the same
 *  descriptive sentence board.tsx used to only show as a native `title`
 *  tooltip on its own tiny icon -- rendered through Ability so a future
 *  card-authored description with its own (percentage) can still get the
 *  purple-word hover treatment for free. Literal branches, not a
 *  constructed `t('board.' + mark)` -- see keywords.ts's own note on why a
 *  built key is one the i18n checker can never find. */
function Effect({ mark, t }: { mark: Mark | 'guard'; t: ReturnType<typeof useT> }) {
  function label(): string {
    if (mark === 'burn') return t('card.burning')
    if (mark === 'poison') return t('card.poisoned')
    if (mark === 'stun') return t('card.stunned')
    if (mark === 'swamp') return t('card.swamped')
    return t('card.guarding')
  }
  function desc(): string {
    if (mark === 'burn') return t('board.burning')
    if (mark === 'poison') return t('board.poisoned')
    if (mark === 'stun') return t('board.stunned')
    if (mark === 'swamp') return t('board.swamped')
    return t('board.guarding')
  }
  return (
    <div className="bc-effect">
      <img className="bc-effect-icon" src={artUrl(MARK_ART[mark])!} alt="" aria-hidden="true" />
      <div className="bc-effect-text">
        <b>{label()}</b>
        <p><Ability text={desc()} /></p>
      </div>
    </div>
  )
}

/**
 * Item 8: My Kingdom's own peek card. A roster `Card` isn't a battle `Unit`
 * -- no owner, no live effects, no hp/maxHp split since nothing has taken
 * damage yet -- so this reads straight off Card's own fields rather than
 * force-fitting one into UnitBigCard's shape. Same Shell, same layout, same
 * long-press-to-open behaviour as every other card this component draws.
 */
export function CardBigCard({ card, side }: { card: Card; side: CardSide }) {
  const t = useT()
  const className = useClassName()
  return (
    <Shell
      side={side} accent={card.accent}
      tone={card.role ? `role-${card.role}` : ''}
    >
      <div className="bc-top">
        <div className="bc-id">
          <FitName>{card.name}</FitName>
          {card.role && <p>{className(card.role)}</p>}
        </div>
        <div className="bc-hp"><b>{card.hp}</b></div>
      </div>

      <div className="bc-artwrap">
        {card.art_url && <img className="bc-art" src={artUrl(card.art_url)!} alt="" />}
      </div>

      <div className="bc-bottom">
        <div className="bc-stats">
          <span><em>{t(card.heals ? 'stat.pwr' : 'stat.dmg')}</em><b>{unitPower(card)}</b></span>
          <span><em>{t('stat.mov')}</em><b>{card.mov}</b></span>
          <span><em>{t('stat.rng')}</em><b>{reachText(card.rmin, card.rmax)}</b></span>
        </div>
        {abilityText(card) && (
          <div className="bc-say">
            <span className="bc-glyph"><RulesMark /></span>
            <p><Ability text={abilityText(card)} /></p>
          </div>
        )}
      </div>
    </Shell>
  )
}

/**
 * Every obstacle gets this card -- a tree, a wall, a trap, a tornado, or
 * whatever an admin has built in Structures (0057+). It used to be a card
 * for TREES, full stop: hard-coded to `t('tree.name')`, `tree.webp` and
 * `tree.note` no matter what was actually on the tile, which is wrong the
 * instant anything else is hovered or long-pressed -- a wall's card said
 * "Tree", a trap's card said "Tree", every one of them showed the tree
 * picture and the tree's own rules text. `fighterInfoFor` (the fight
 * cinematic's own name/art/accent lookup) and `Thing`/`ThingGlyph` (the
 * on-board renderer), both in Board.tsx, already resolve a kind correctly
 * -- this card just never got the same treatment when custom structures
 * were introduced. Fixed the same way here, reusing those two rather than
 * a second copy of their logic: `fighterInfoFor` for name/art/accent (its
 * own i18n-first, catalog-second order keeps the four built-in kinds
 * translated, since only they have a dictionary entry -- see
 * objNameKey's own comment), and `ThingGlyph` for the icon whenever there
 * is no uploaded `art_url` to show instead.
 *
 * 0079 adds the actual "details" Jared asked this card be able to show:
 * `structures.description`/`description_es`, an admin-editable sentence
 * per structure -- same bilingual-column convention as a card's own
 * ability/ability_es text, and the same reason (prose an admin might
 * reword shouldn't need a deploy). The four built-in kinds predate that
 * column and are unlikely to ever get one filled in through the admin UI,
 * so they fall back to their own long-standing note text instead of a
 * card that otherwise has nothing to say in its bottom half.
 */
export function TreeBigCard({ tree, side }: { tree: Obstacle; side: CardSide }) {
  const t = useT()
  const structuresBySlug = useStructuresBySlug()
  const kind = objKind(tree)
  const row = structuresBySlug.get(kind)
  const { name, art, accent } = fighterInfoFor(kind, structuresBySlug, t)
  const isTree = kind === 'tree'

  // Since 0064, EVERY kind -- tree and wall included -- is a real
  // `structures` row, seeded with the exact blocks_movement the old
  // hard-coded branch used (true for tree/wall, false for bomb/tornado).
  // Falling back to that same true/false only covers a row this client
  // hasn't fetched yet.
  const blocks = row?.blocks_movement ?? (isTree || kind === 'wall')
  const legacyNote = kind === 'wall' ? t('wall.note')
    : kind === 'bomb' ? t('bomb.note')
    : kind === 'tornado' ? t('tornado.note')
    : isTree ? t('tree.note')
    : ''
  const note = (currentLang() === 'es' ? row?.description_es : row?.description) || legacyNote

  return (
    <Shell side={side} tone="bigcard-tree" accent={accent}>
      <div className="bc-top">
        <div className="bc-id"><FitName>{name}</FitName><p>{t('tree.role')}</p></div>
        <div className="bc-hp"><b>{tree.hp}</b><i>/{tree.maxHp}</i></div>
      </div>
      <div className="bc-artwrap">
        {isTree ? (
          <img className="bc-art" src={`${import.meta.env.BASE_URL}tree.webp`} alt="" />
        ) : art ? (
          <img className="bc-art" src={artUrl(art)!} alt="" />
        ) : (
          <div className="bc-glyphwrap"><ThingGlyph kind={kind} /></div>
        )}
      </div>
      <div className="bc-bottom">
        {blocks && (
          <div className="bc-stats">
            <span><em>{t('tree.blocks')}</em><b>{t('tree.blocksWhat')}</b></span>
          </div>
        )}
        {note && (
          <div className="bc-say">
            <span className="bc-glyph"><RulesMark /></span>
            <p><Ability text={note} /></p>
          </div>
        )}
      </div>
    </Shell>
  )
}
