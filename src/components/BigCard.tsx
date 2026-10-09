import { useLayoutEffect, useRef, useState, type ReactNode } from 'react'
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
import { Ti } from './Ti'
import { TI } from '../lib/tablerIcons'
import { useAppSettings } from '../lib/useAppSettings'

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

const CLASS_ROLES = new Set(['royal', 'rogue', 'knight', 'mage', 'flying'])

/** The white class icon Jared drew for each of the five classes (public/classes). */
function classIconUrl(role: string | null | undefined): string | null {
  return role && CLASS_ROLES.has(role) ? `${import.meta.env.BASE_URL}classes/${role}.png` : null
}

/** "001". The number on the tag under the name, padded to three places. */
function cardNo(n: number | null | undefined): string {
  return n == null ? '' : String(n).padStart(3, '0')
}

/**
 * The ability sentence is fitted, not clamped: it steps down until it stops
 * overflowing the box it sits in, because a card that cuts its own rules text
 * short is worse than one with smaller type. Same one-measurement-per-mount
 * approach as FitName.
 */
function FitSay({ children, sig }: { children: ReactNode; sig: string }) {
  const box = useRef<HTMLDivElement>(null)
  const txt = useRef<HTMLParagraphElement>(null)
  useLayoutEffect(() => {
    const b = box.current, p = txt.current
    if (!b || !p) return
    let k = 1
    b.style.setProperty('--sfit', '1')
    while (p.scrollHeight > b.clientHeight - 2 && k > 0.5) {
      k -= 0.05
      b.style.setProperty('--sfit', k.toFixed(2))
    }
  }, [sig])
  return <div ref={box} className="bc-say"><p ref={txt}>{children}</p></div>
}

interface FaceStats {
  heals: boolean
  power: number
  mov: number
  reach: string
}

/**
 * The face of the card, drawn on Jared's 3100 x 4350 reference (see the
 * .bc-* block in styles.css, where every number is a measurement off it):
 * full-bleed art; the class tile and name on a white bar; "001 | CLASS" under
 * it; HP in one red chip top right; three coloured stat rhomboids; and one
 * white box for the ability, with the class-coloured block, a white icon the
 * admin picks per card, and a red chip with the damage.
 */
function Face({ name, tile, tag, hpNow, hpMax, art, stats, abiIcon, say, effects }: {
  name: string
  tile: ReactNode
  tag: string
  /** Current HP, and the maximum -- shown as "/max" only once damaged. */
  hpNow: number
  hpMax?: number | null
  art: ReactNode
  stats?: FaceStats
  abiIcon: string
  say: string
  effects?: ReactNode
}) {
  const t = useT()
  const cfg = useAppSettings()
  const damaged = hpMax != null && hpNow < hpMax
  // The red chip is as wide as its number needs, but the white block beside
  // the name bar has a hard left limit, so a long reading ("110", "85/110")
  // shrinks instead of growing: ~436 reference px of text, 0.6 em per digit,
  // and the "/max" at 0.42 em.
  const w = String(hpNow).length + (damaged ? (String(hpMax).length + 1) * 0.42 : 0)
  const hpk = Math.min(1, 436 / (0.6 * w) / 268)
  return (
    <>
      {art}
      <div className="bc-bar" />
      <div className="bc-bar-stripe" />
      <div className="bc-tile">{tile}</div>
      <FitName>{name}</FitName>
      <div className="bc-tag">{tag}</div>
      <div className="bc-hp">
        <div className="bc-chip" style={{ '--hpk': hpk } as React.CSSProperties}>
          {hpNow}{damaged && <i>/{hpMax}</i>}
        </div>
      </div>

      {effects}

      {stats && (
        <div className="bc-stats">
          <div className="bc-stat mov">
            <Ti name={cfg.stat_icon_mov ?? 'walk'} filled className="ti" />
            <span>{t('stat.mov')}</span><b>{stats.mov}</b>
          </div>
          <div className="bc-stat rng">
            <Ti name={cfg.stat_icon_rng ?? 'target'} filled className="ti" />
            <span>{t('stat.rng')}</span><b>{stats.reach}</b>
          </div>
          <div className="bc-stat atk">
            <Ti name={cfg.stat_icon_atk ?? 'sword'} filled className="ti" />
            <span>{t(stats.heals ? 'stat.pwr' : 'stat.atk')}</span><b>{stats.power}</b>
          </div>
        </div>
      )}

      <div className="bc-abi">
        <div className="bc-abi-tile">
          <Ti name={TI[abiIcon] ? abiIcon : 'sparkles'} filled className="ti" />
        </div>
        <FitSay sig={say}>{say && <Ability text={say} />}</FitSay>
      </div>
      <div className="bc-abi-stripe" />
      <div className="bc-foot">CROWN NEMESIS™ 2026 | BY JAREDARTT</div>
    </>
  )
}

/** The print files are 820 x 1120: the 744 x 1044 card plus a 38px bleed on
 *  every side, so the illustration can run past the trim. */
const BLEED_RATIO = 820 / 1120

/**
 * The illustration, full bleed, trimmed.
 *
 * Art that has the print proportions (820 x 1120) is drawn at its true size
 * relative to the card -- 110.2% wide, 107.3% tall, centred -- so the 38px
 * bleed falls outside the card and is cropped by it, and what shows is exactly
 * the 744 x 1044 trim. Anything else (the older square art) is just covered
 * to the card, as before. The proportions are read off the loaded picture, so
 * uploading a bleed file in the admin is all it takes.
 */
function FaceArt({ src, glyph }: { src: string | null | undefined; glyph?: ReactNode }) {
  const [bleed, setBleed] = useState(false)
  const img = useRef<HTMLImageElement>(null)
  const check = () => {
    const i = img.current
    if (i && i.naturalWidth && i.naturalHeight) {
      setBleed(Math.abs(i.naturalWidth / i.naturalHeight - BLEED_RATIO) < 0.02)
    }
  }
  useLayoutEffect(check, [src])
  if (src) {
    return (
      <img
        ref={img} className={`bc-art${bleed ? ' is-bleed' : ''}`}
        src={artUrl(src)!} alt="" onLoad={check}
      />
    )
  }
  return <div className="bc-glyphwrap">{glyph}</div>
}

/** The tile at the top left: the class's white icon, or a stand-in. */
function ClassTile({ role, fallback }: { role: string | null | undefined; fallback?: string }) {
  const url = classIconUrl(role)
  if (url) return <img src={url} alt="" />
  return <Ti name={fallback ?? 'diamond'} filled className="ti" />
}

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
  const row = bySlug.get(unit.slug)
  const say = abilityText(row) || unit.ability
  // Same list Board.tsx's own (now-deleted) unit-marks row used to build --
  // swamp is positional rather than a field on the unit, so it is passed in
  // by whoever has the board in hand rather than read off `unit` itself.
  const marks: Mark[] = [...afflictionsOf(unit), ...(swamped ? ['swamp' as const] : [])]
  const no = cardNo(row?.card_no)
  const cls = unit.role ? className(unit.role) : ''
  return (
    <Shell
      side={side} pinned={pinned} accent={unit.accent}
      // The chrome reads the CLASS, not the owner -- see the .bigcard.role-*
      // rules in styles.css -- so a Royal card is orange and a Mage's is
      // purple, same as the board's own hover/select ring.
      tone={`${unit.owner === 'host' ? 'unit-host' : 'unit-guest'}${unit.role ? ` role-${unit.role}` : ''}`}
    >
      <Face
        name={unit.name}
        tile={<ClassTile role={unit.role} />}
        tag={[no, cls].filter(Boolean).join(' | ')}
        hpNow={unit.hp} hpMax={unit.maxHp}
        art={<FaceArt src={unit.art} />}
        stats={{ heals: !!unit.heals, power: unitPower(unit), mov: unit.mov, reach: reachText(unit.rmin, unit.rmax) }}
        abiIcon={row?.ability_icon ?? 'sparkles'}
        say={say}
        effects={(unit.defending || marks.length > 0) && (
          // Jared: "a box right next to the hovered/clicked/long-pressed card,
          // saying all the effects they have, with their respective icon, and
          // a short description". One row per active mark, guard included.
          <div className="bc-effects">
            {unit.defending && <Effect mark="guard" t={t} />}
            {marks.map((m) => <Effect key={m} mark={m} t={t} />)}
          </div>
        )}
      />
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
  const className = useClassName()
  const say = abilityText(card)
  return (
    <Shell
      side={side} accent={card.accent}
      tone={card.role ? `role-${card.role}` : ''}
    >
      <Face
        name={card.name}
        tile={<ClassTile role={card.role} />}
        tag={[cardNo(card.card_no), card.role ? className(card.role) : ''].filter(Boolean).join(' | ')}
        hpNow={card.hp}
        art={<FaceArt src={card.art_url} />}
        stats={{ heals: card.heals, power: unitPower(card), mov: card.mov, reach: reachText(card.rmin, card.rmax) }}
        abiIcon={card.ability_icon ?? 'sparkles'}
        say={say}
      />
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

  const blockLine = blocks ? `${t('tree.blocks')}: ${t('tree.blocksWhat')}` : ''
  return (
    <Shell side={side} tone="bigcard-tree" accent={accent}>
      <Face
        name={name}
        tile={<Ti name={TI[kind] ? kind : 'diamond'} filled className="ti" />}
        tag={t('tree.role')}
        hpNow={tree.hp} hpMax={tree.maxHp}
        art={
          <FaceArt
            src={isTree ? `${import.meta.env.BASE_URL}tree.webp` : art}
            glyph={<ThingGlyph kind={kind} />}
          />
        }
        abiIcon={TI[kind] ? kind : 'diamond'}
        say={[blockLine, note].filter(Boolean).join('. ')}
      />
    </Shell>
  )
}
