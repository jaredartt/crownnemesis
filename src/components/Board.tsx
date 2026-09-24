import { Fragment, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { MatchState, Obstacle, Side, Unit } from '../lib/types'
import type { Ghost } from '../lib/useGhost'
import { getSettings, lessMotion } from '../lib/settings'
import { buildCine, fighterOf, fighterOfTree, quicken, type Cine } from '../lib/cine'
import { useT } from '../lib/i18n'
import { Duel } from './Duel'
import { artUrl, faceUrl } from '../lib/art'
import {
  canAct, cheb, deployTiles, draw, drawSign, flipFor, key, losClear, occupied,
  ownSide, pathTo, reachable,
  targetsFor, undraw, willCounterOn, type Target,
} from '../lib/rules'
import { playMove, playPlace, playSelect } from '../lib/sfx'
import { playCardSound } from '../lib/customAudio'
import { useCardsBySlug } from '../lib/useCards'
import {
  isBurning, isPoisoned, isStunned, afflictionsOf, MARK_ART,
  type Affliction, type Mark,
} from '../lib/effects'
import { awake, isSwamped } from '../lib/swamp'
import { HitBurst } from './HitBurst'
import { StatusBurst } from './StatusBurst'
import { HealBurst } from './HealBurst'
import { THROW_REACH, objKind, objNameKey, objSolid, type ObjKind } from '../lib/objects'
import { useLongPress } from '../lib/useLongPress'
import { useStructuresBySlug } from '../lib/useStructures'
import type { ConditionNode, Structure } from '../lib/types'
import { Modal } from './Modal'
import { IconArrowUp, IconClose, IconRhombus, IconSword } from './Icons'

// No pixel sizes here on purpose. The board is a CSS grid that fills whatever
// space it is given and keeps its aspect ratio.
const MAX_TILT = 16   // degrees the card leans toward the cursor

const FX_MS = 1300
// How long a newly arrived structure spends tilting itself down onto the
// board -- see .tree.is-landing in styles.css. Independent of FX_MS: once
// the ability branch below stopped freezing the board (see that branch's
// own comment), nothing is holding this hostage to the pop-number timer
// any more, so it is free to be whatever reads best as a placement.
const LANDING_MS = 650
// Each army's entrance -- yours the instant the deploy screen first shows
// it, theirs once "all players are ready" hands back the real board (see
// the `reveal`/`mineCount`/`theirsCount` block below). Borrows LANDING_MS
// and .unit-slot.is-landing's exact `structure-land` keyframes wholesale
// (Jared: the same effect the structures get when they're summoned) rather
// than inventing a second animation that happens to look the same.
// REVEAL_START_MS is the pause before a wave's first unit starts (Jared:
// "after 0.2 seconds"); REVEAL_STEP_MS is how much later than the one
// before it each next unit in that wave starts, sorted left to right on
// screen.
const REVEAL_START_MS = 200
const REVEAL_STEP_MS = 70
// The ground itself, before any of that: every tile fades and tilts down
// into place, staggered by how far a tile sits from the top-left corner ON
// SCREEN (the drawn/flipped x+y, not the raw one -- see the `d` used below)
// so the grid visibly grows outward from that corner toward the bottom-
// right rather than popping in at once.
//
// Jared: "the board should spawn... right before players see their cards
// being spawned" -- not simply BEFORE the army wave starts, but genuinely
// FINISHED first, and not until the VS screen (now the very first thing a
// match shows, see Match.tsx's GET_READY_MS/showVsIntro) has actually
// closed. So unlike every other reveal in this file, the tiles' own
// `animation` is no longer unconditional CSS fired at first paint --
// `.tile` only gets `.is-revealing` (see styles.css) once the effects
// below decide the moment has come, the same `introOpen`-gated dance
// `theirsStarted` already does lower down. TILE_REVEAL_STEP_MS is that
// sweep's own per-tile stagger; TILE_ENTER_MS mirrors tile-enter's own
// animation-duration in styles.css (edit both together); TILES_DONE_MS is
// the worst case the whole sweep can take, for a board this shape --
// against the current 6x8 board (see fresh_board_state() in
// 0031_roster_numbers.sql) the farthest tile's diagonal distance is 11, so
// the last one starts at 11 * 45 = 495ms and finishes at 495 + 300 = 795ms
// -- deliberately in LANDING_MS's own neighbourhood (650ms) rather than
// the ~300ms this originally shipped at, which Jared found unreadable as a
// sweep at all: with the VS screen gone and nothing else moving, a whole
// board's worth of tiles finishing inside a third of a second just reads
// as "appeared". MINE_AFTER_TILES_MS is the beat left after all of that
// before your own army starts landing on top of it, below. The initial
// trees standing on the board when a match starts ride this exact same
// wave now too (see initialTreeIds below) -- they used to just appear with
// no entrance at all, since the existing `arrivals` landing animation
// only ever fired for a tree that showed up mid-match.
const TILE_REVEAL_STEP_MS = 45
const TILE_ENTER_MS = 300
const TILES_DONE_MS = 11 * TILE_REVEAL_STEP_MS + TILE_ENTER_MS
const MINE_AFTER_TILES_MS = 160
// How long a fresh affliction's round mini-explosion plays before it fades
// into the ongoing whole-card pulse (.unit.is-burned/-poisoned/-stunned::after
// in styles.css). Its own constant, not FX_MS/LANDING_MS: it is a different
// thing happening to a different element, and nothing ties its length to
// either of those.
const STATUS_BURST_MS = 600

interface Props {
  state: MatchState
  mySide: Side | null
  isMyTurn: boolean
  deploying: boolean
  selectedId: string | null
  onSelect: (id: string | null) => void
  onMove: (x: number, y: number) => void
  onAttack: (targetId: string) => void
  /** `target` is null for an ability that takes none. */
  onAbility: (unitId: string, target: string | null) => void
  /** Answer the open decision: a tile ('@x,y') to throw them there, or null to
   *  let them go. Optional, so the harnesses that mount a Board without one
   *  keep working. */
  onThrow?: (target: string | null) => void
  onDefend: (unitId: string) => void
  onDeploy: (unitId: string, x: number, y: number) => void
  /** The unit or tree the pointer is over. The card it opens is drawn beside
   *  the board, not inside it, so the board reports and Match renders. */
  onHover: (id: string | null) => void
  /** The unit or tree a finger has just been held on -- see useLongPress.
   *  Fires ONCE, on the press; the card it opens stays until something
   *  dismisses it, which is Match's business rather than the board's. It used
   *  to close on release, which meant reading a card with your own finger over
   *  the board, and made the purple keywords on it untappable. */
  onPeek?: (id: string) => void
  /** Where the opponent is looking, and a way to tell them where you are.
   *  Both optional: a board with neither is simply a board with no ghost on
   *  it, which is what deployment and a finished match should be. */
  ghost?: Ghost | null
  onLook?: (g: { tile: { x: number; y: number } | null; unit: string | null;
                 mode: 'menu' | 'move' | 'attack' | null }) => void
  /** True while a fight is on screen. The bot takes an action every 650ms and
   *  a fight takes seconds, so without this it plays its whole turn behind the
   *  cinematic and you watch the fights it had rather than the fights it is
   *  having. */
  onWatching?: (busy: boolean) => void
  /** True while Match.tsx has the VS intro up. The army's own entrance (see
   *  REVEAL_STEP_MS) waits for this to close before it plays a single frame --
   *  otherwise it would run its whole ~1.3s underneath a ~2.6s title card and
   *  be over before anyone could see it. Optional so the harnesses that mount
   *  a Board without Match around it keep working; a Board that never hears
   *  otherwise assumes there is nothing covering it. */
  introOpen?: boolean
  /** The match this board belongs to. A rematch does not remount Board --
   *  Match.tsx keeps the same mounted component and simply points `state` at
   *  a new room under it (see Match.tsx's own comment on `showVsIntro` for
   *  why: a rematch is a new id in the same component). Optional so the
   *  harnesses that mount a Board without Match around it keep working; a
   *  Board that never hears a matchId simply never resets, same as today. */
  matchId?: string
  /** True while a turn-announcement band is up (see TurnBand.tsx) -- Jared:
   *  "while those bands are there, no player can actually do anything to
   *  modify the board... only viewing cards' information (hovering or long
   *  pressing)". Gates exactly clickTile/clickUnit, the two functions that
   *  ever call onMove/onAttack/onAbility/onDeploy/onDefend/onThrow -- hover
   *  (onHover) and long-press (onPeek) are wired straight to onMouseEnter/
   *  useLongPress on each token, entirely separately from those two, so they
   *  keep working right through a locked band exactly as asked. Optional,
   *  default false, so the harnesses that mount a Board without a Match
   *  around it keep working unlocked, same as today. */
  locked?: boolean
}

const watching = (side: Side | null) => side === null

interface Blow {
  seq: number
  atk: string
  tgt: string
  dmg: number
  heal: number
  counter: number
  burnAtk: number
  burnTgt: number
  killedTgt: boolean
  killedAtk: boolean
  atkAt: { x: number; y: number }
  tgtAt: { x: number; y: number }
  atkUnit: Unit
  tgtUnit: Unit | null
}

/**
 * What the board is waiting for. Fire Emblem's shape: clicking a unit of yours
 * opens its menu and nothing is lit, and only once you have chosen Move or
 * Attack does the board light up for the thing you chose. Lighting both at
 * once -- which is what this did before -- makes a tile and a target look like
 * alternatives when they are two halves of one go.
 */
// 'ability' is the aimed kind only. Back to Back and the Mist have nothing to
// point at, so they fire from the menu and never become a mode.
type Mode = 'menu' | 'move' | 'attack' | 'ability'

/**
 * The actual name/art/accent for whatever is standing on this tile, for the
 * fight cinematic's own panel (cine.ts's fighterOfTree). Before this, every
 * obstacle -- a wall, a trap, a custom structure, anything -- drew as a
 * hardcoded 'Tree' with no art: the whole of the bug this fixes. The four
 * legacy kinds (tree/wall/bomb/tornado) keep their existing translated
 * name (objNameKey/en.json's "obj.*" keys, same as their on-board tooltip
 * already uses) rather than the catalog's own lowercase `name` column
 * ('a tree') -- a custom structure has no such key, so it falls back to the
 * catalog's own name, and finally to the raw kind string if the catalog
 * fetch has not landed yet.
 */
/**
 * Best-effort: does this conditions tree mention target.is_enemy anywhere,
 * true rather than negated? Since 0075 a `conditions` array can nest
 * ALL/ANY groups (see types.ts's ConditionNode), and this is only ever a
 * client-side HINT for which crosshair colour to preview -- cn_target_in_
 * range/cn_effect_conditions_met on the server are what actually decide,
 * reading the real tree correctly (AND vs OR, negation and all). Walking
 * every leaf regardless of which ALL/ANY branch it sits under is not a
 * sound reduction of the whole boolean tree to one flag, but it is a
 * strict improvement over missing every condition inside a group entirely
 * (which is what a flat .some() over the top level always did before
 * groups existed) and it fails safe: worst case is a preview that lights a
 * target the server still refuses, the same "rejected round-trip, not an
 * illegal one that lands" this file's known-gaps already accept elsewhere.
 */
function isGroupNode(n: ConditionNode): n is Extract<ConditionNode, { kind: 'group' }> {
  return (n as { kind?: string }).kind === 'group'
}

function mentionsEnemyOnly(nodes: ConditionNode[]): boolean {
  return nodes.some((n) => {
    if (isGroupNode(n)) return mentionsEnemyOnly(n.children)
    return n.field === 'target.is_enemy' && n.op !== '!=' && n.value !== 'false' && !n.negate
  })
}

// Exported (0079) so BigCard.tsx's hover/long-press card can resolve the
// same kind-aware name/art/accent this file's own fight cinematic always
// has -- see that file's TreeBigCard for why it needed this.
export function fighterInfoFor(
  kind: ObjKind, structuresBySlug: Map<string, Structure>, t: (k: string) => string,
) {
  const nameKey = objNameKey(kind)
  const row = structuresBySlug.get(kind)
  return {
    name: nameKey ? t(nameKey) : (row?.name ?? kind),
    art: row?.art_url ?? null,
    accent: row?.accent ?? '#6b8f4e',
  }
}

export function Board({
  state, mySide, isMyTurn, deploying, selectedId, onSelect, onMove, onAttack, onAbility, onThrow, onDefend,
  onDeploy, onHover, onPeek, ghost = null, onLook, onWatching, introOpen = false, matchId,
  locked = false,
}: Props) {
  const t = useT()
  const { w, h } = state.board
  // What the board DRAWS. Held one exchange behind while a fight is being
  // told -- see the `frozen` block below -- and identical to `state` at every
  // other moment, which is almost every moment.
  const trees: Obstacle[] = state.obstacles ?? []
  const selected = state.units.find((u) => u.id === selectedId) ?? null
  // Since 0040, for the custom walking sound below only -- nothing that
  // decides where a unit may go reads this.
  const bySlug = useCardsBySlug()
  // For the fight cinematic's own fighterOfTree call below only -- nothing
  // that decides movement or targeting reads this either. See
  // fighterInfoFor's own comment.
  const structuresBySlug = useStructuresBySlug()

  // The board turns half a turn for the host, and for nobody else -- see
  // flipFor(), which is where the surprise in that sentence is explained. 0019
  // gave the halves back to the rows, and the whole point of doing the turn in
  // the client is that the database never learns about it: one set of
  // coordinates, two pictures of it. You are always at the bottom, looking up.
  //
  // Every coordinate that reaches the screen goes through draw(), and nothing
  // that reaches the server does. If you find yourself flipping a coordinate
  // anywhere else, it belongs here instead.
  const flip = flipFor(mySide)
  const at = (p: { x: number; y: number }) => {
    const d = draw(p, w, h, flip)
    return ({ gridColumn: d.x + 1, gridRow: d.y + 1 }) as React.CSSProperties
  }

  // A card changes square by changing which grid cell it is in, which is
  // instant and unreadable, so we play the change back: put the card where it
  // used to be and let it travel. Ease-out only -- a piece that starts fast
  // and settles reads as a move, one that starts slow reads as a drag.
  //
  // What moved is decided from the units' OWN coordinates, and the distance
  // from the current tile pitch. Comparing screen rectangles between renders
  // was wrong: the arena is sized from its container, so anything that changes
  // the page height -- the strip under the board growing a line, the away
  // notice appearing, a phone rotating -- shifts every card a few pixels, and
  // the whole army would slide at once for no reason.
  //
  // And nothing legal moves more than two pieces at a time: a turn moves one,
  // a deployment swap moves two. More than that means the board underneath us
  // was replaced -- a rematch reusing the same unit ids, a reconnect, a
  // spectator arriving mid-game -- where the right answer is to appear, not to
  // fly in from wherever a namesake happened to be standing.
  const seats = useRef(new Map<string, { x: number; y: number }>())
  const slots = useRef(new Map<string, HTMLDivElement>())
  useLayoutEffect(() => {
    const live = new Set<string>()
    const moves: { el: HTMLDivElement; dx: number; dy: number }[] = []

    const movedIds: string[] = []
    for (const u of state.units) {
      live.add(u.id)
      const was = seats.current.get(u.id)
      seats.current.set(u.id, { x: u.x, y: u.y })
      const el = slots.current.get(u.id)
      if (!el || !was || (was.x === u.x && was.y === u.y)) continue
      // An exchange already owns this element's transform; do not fight it.
      if (el.className.includes('fx-')) continue

      const cell = el.getBoundingClientRect()
      const gs = el.parentElement ? getComputedStyle(el.parentElement) : null
      const gapX = parseFloat(gs?.columnGap ?? '0') || 0
      const gapY = parseFloat(gs?.rowGap ?? '0') || 0
      // Drawn deltas, not board deltas: on a flipped board a step north is
      // played back as a step south, and a piece that travels the wrong way
      // and arrives in the right place reads as a glitch rather than a move.
      const sgn = drawSign(flip)
      moves.push({
        el,
        dx: sgn * (was.x - u.x) * (cell.width + gapX),
        dy: sgn * (was.y - u.y) * (cell.height + gapY),
      })
      movedIds.push(u.id)
    }

    if (moves.length <= 2) {
      // Jared, first asking for this: "smooth tilts when the card is
      // moving" -- then, once it turned out too subtle to actually notice
      // in a real match: "they should tilt... towards the direction they
      // aim to move so that it looks realistic and super cool" for BOTH
      // armies (this diff never distinguished owner to begin with -- it
      // reads every unit's own before/after tile the same way regardless of
      // whose it is, so the previous pass already covered the opponent's
      // moves too; it was just as hard to see on theirs as on your own).
      // Flat at both ends -- still flush with its old tile at 0%, already
      // settled flush onto the new one at 100% -- and leaned into the
      // direction it is actually travelling only at the midpoint, the same
      // "banking into the turn" read the move triangle's own float already
      // leans on elsewhere on this board. The element starts at (dx, dy)
      // and animates TOWARD (0, 0), so the travel direction is the OPPOSITE
      // sign of dx/dy. Angles roughly tripled from the first pass (6/5 deg
      // -> 18/13), then Jared asked for the lean to actually be 3D rather
      // than a flat spin: "tilt in a 3D axis to make it look cooler" --
      // `roll` was riding the plain `rotate()` function this whole time,
      // which is a flat Z-axis spin (the card stays face-on to the camera
      // and just turns like a clock hand), not a tilt at all. Switched it to
      // `rotateY()` -- a true yaw around the vertical axis, banking the
      // card's near/far edge toward or away from the viewer the way `pitch`
      // (`rotateX`) already does on the other axis -- and bumped both angles
      // (18/13 -> 26/16) since a true 3D rotation foreshortens at these
      // angles and reads noticeably softer than the old flat spin did at the
      // same number. Turned up an actual, separate bug while doing that:
      // `.unit-slot` (this element, `m.el` itself) declares its own
      // `perspective: 800px`, and CSS's `perspective` PROPERTY only ever
      // applies to an element's CHILDREN -- it has no effect on the element
      // that declares it. So every rotateX/rotateY this block has ever
      // played was rendering with no vanishing point at all: a true
      // orthographic (flat) 3D rotation, which reads as the card getting
      // thinner rather than as it tilting away in space. That is very
      // likely a real reason the original 6/5deg pass read as nearly
      // invisible (issue 35) -- it wasn't just small, it had no depth cue to
      // sell it as a tilt in the first place. Fixed at the point of use
      // instead of restructuring the DOM: `perspective(...)` is also a
      // TRANSFORM FUNCTION, not just a property, and chaining it into the
      // front of this element's own `transform` list gives that same
      // transform its own perspective divide directly, no wrapping element
      // needed.
      //
      // Also gave the browser a `will-change` hint for exactly the
      // animation's own lifetime, not longer: promoting an element to its
      // own compositor layer costs something the first time it happens, and
      // on a slower phone that one-time cost can land as a dropped frame
      // right as the animation starts -- which reads as "choppy", is easy
      // to miss on a fast desktop, and would explain Jared seeing it only
      // sometimes on mobile rather than reliably anywhere. Asking for the
      // promotion a tick before `animate()` starts, and dropping the hint
      // the moment it finishes, gets that promotion out of the animation's
      // own critical path without leaving every idle unit sitting on its
      // own GPU layer for the whole match.
      const flat = lessMotion()
      for (const m of moves) {
        m.el.style.willChange = 'transform'
        const anim = flat
          ? m.el.animate(
              [{ transform: `translate(${m.dx}px, ${m.dy}px)` }, { transform: 'translate(0px, 0px)' }],
              { duration: 240, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' },
            )
          : (() => {
              const travelX = Math.sign(-m.dx)
              const travelY = Math.sign(-m.dy)
              const roll = travelX * 26   // deg, rotateY -- a sideways step banks its near edge into the turn, a true 3D yaw
              const pitch = travelY * -16 // deg, rotateX -- a step toward the viewer dips the near edge down; a step away tips it back
              // Every keyframe carries the SAME transform functions, in the
              // same order, just at 0deg on the two flat ends -- not merely
              // `translate(...)` at 0%/100% and a longer list at the
              // midpoint. Mismatched transform lists between keyframes force
              // the browser to fall back to matrix decomposition to
              // interpolate between them, which is unreliable exactly where
              // a `perspective`-affected 3D matrix is involved; an identical
              // function list at every keyframe lets it interpolate each
              // function on its own (a plain lerp of each angle/offset),
              // which is the reliable path and the one actually meant here.
              // `perspective(...)` no longer needs to be IN this list at
              // all -- it now lives on .board itself (styles.css), the
              // direct parent of this element, which is the ordinary,
              // unambiguous place for it (a perspective PROPERTY never
              // affects the element that declares it, only its children).
              return m.el.animate(
                [
                  { transform: `translate(${m.dx}px, ${m.dy}px) rotateY(0deg) rotateX(0deg)` },
                  {
                    transform: `translate(${m.dx * 0.45}px, ${m.dy * 0.45}px) rotateY(${roll}deg) rotateX(${pitch}deg)`,
                    offset: 0.55,
                  },
                  { transform: 'translate(0px, 0px) rotateY(0deg) rotateX(0deg)' },
                ],
                { duration: 300, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' },
              )
            })()
        const el = m.el
        anim.finished
          .catch(() => {}) // a cancelled/replaced animation rejects here; nothing to clean up beyond dropping the hint below
          .then(() => { el.style.willChange = '' })
      }
      // One sound for the whole change, not one per card: a deployment swap
      // is two cards but a single act. Sounding it here rather than in the
      // click handler means the opponent's move is audible too, and means a
      // move the server refused stays silent.
      if (moves.length) (deploying ? playPlace : playMove)()
      // Since 0040. Deploying is a placement, not a walk -- so this is only
      // for an ordinary move, and only for cards that actually uploaded a
      // walking sound. A deployment swap can move two units at once; both get
      // a chance to sound, same as the built-in playMove above would for
      // either.
      if (!deploying) {
        for (const id of movedIds) {
          const u = state.units.find((x) => x.id === id)
          if (u) playCardSound(bySlug.get(u.slug) ?? null, 'walk')
        }
      }
    }
    for (const id of [...seats.current.keys()]) if (!live.has(id)) seats.current.delete(id)
  })

  // The board a moment ago. A killed unit is gone from `state.units` by the
  // time we hear about it, so the only place its last position still exists
  // is the previous render's copy.
  const before = useRef<{ units: Unit[]; trees: Obstacle[] }>({ units: state.units, trees })
  const lastSeq = useRef<number>(state.fx?.seq ?? 0)
  const [blow, setBlow] = useState<Blow | null>(null)
  // AN ABILITY LANDS ON ANY NUMBER OF UNITS AT ONCE, which `blow` -- built for
  // an exchange between exactly two -- cannot hold. Back to Back hits
  // everything around it in one go, so its numbers get their own little piece
  // of state rather than a `blow` bent into a shape it was never for.
  const [pops, setPops] = useState<{ id: string; dmg?: number; heal?: number }[]>([])
  // A unit gone from the board that `blow` above does NOT already explain --
  // any death that does not run through cn_attack's own swing loop: a custom
  // card/structure effect applied through the admin "what it does" engine
  // (cn_effect_apply_action's DEAL_DAMAGE and friends), a poison/burn tick at
  // turn start, an AoE ability (Back to Back and its kin never carry
  // killedTgt/killedAtk at all -- 'any number of targets' has no room for
  // that shape). None of those stamp state.fx with a kill the way an
  // exchange does, so the ONLY signal the client ever gets is the unit
  // itself missing from state.units on the next render -- see the diff
  // against `before.current` below. Keyed by a local counter rather than
  // fx.seq, since most of these deaths never move fx.seq at all.
  const [deathGhosts, setDeathGhosts] = useState<{ id: string; seq: number; unit: Unit }[]>([])
  const deathSeq = useRef(0)

  // The exchange, as a cinematic. Built HERE because this is where the board a
  // moment ago still exists: a unit killed by the blow is gone from
  // `state.units` by the time we hear about it, and the duel has to show it
  // standing before it falls. Health is walked forward from this snapshot for
  // the same reason -- see buildCine.
  // A QUEUE and not a slot. Exchanges can arrive faster than they can be
  // watched -- the bot takes its second activation while you are still
  // watching its first, and so can a human who is quick about it. Replacing
  // the one on screen would cut a fight off halfway through and show you the
  // aftermath of one you never saw; the answer is to watch them in order.
  const [queue, setQueue] = useState<Cine[]>([])
  const cine = queue[0] ?? null
  // Stable on purpose. A fresh arrow here on every render would re-run the
  // cinematic's scheduling effect and restart it from the top -- the same
  // shape of bug as the blank rematch page.
  const endCine = useCallback(() => setQueue((q) => q.slice(1)), [])

  // NO SPOILERS. The board used to install the new state the moment it
  // arrived and THEN play the exchange over the top of it, so for the two or
  // three frames before the cinematic opened you could read the result off
  // the health bars -- and a unit that had fallen was already gone from the
  // board it was about to fall on. Jared: "there's like some frames before
  // the battle animation that you can see the final result in the tokens".
  //
  // So the board draws the board as it was UNTIL the telling of it is over.
  // Only the drawing is frozen; every rule below still reads `state`, which is
  // correct and also moot, because nobody may act while a fight is on screen.
  const [frozen, setFrozen] = useState<{ units: Unit[]; trees: Obstacle[] } | null>(null)
  const [holdUntil, setHoldUntil] = useState(0)
  // Jared: fight scenes sometimes skipped, moves sometimes teleported instead
  // of animating. Root cause (see Match.tsx's `guard`/`busy` comment for the
  // full writeup): nothing stopped a second action from firing while an
  // exchange was still being held/told on screen. `queue.length > 0` alone
  // missed the gap between an exchange landing (`frozen` gets set here) and
  // it actually being queued as a cinematic -- and misses it entirely when
  // cine mode is 'off', where `queue` never populates at all even though the
  // board is still deliberately holding the old frame. `frozen != null` is
  // the precise, mode-independent signal for "an exchange is being held."
  useEffect(() => { onWatching?.(queue.length > 0 || frozen != null) }, [queue.length, frozen, onWatching])
  // Structures currently playing their landing animation, each keyed to its
  // own stagger delay in ms -- see Thing's `landing`/`landingDelayMs` props
  // and .tree.is-landing in styles.css. A structure that arrives mid-match
  // (the `arrivals` diff below) always gets 0 -- it lands all at once, same
  // as it always has. The trees standing on the board before the match's
  // first move ride wave zero's own diagonal sweep instead, each with its
  // own delay computed in revealTiles() below.
  const [landingIds, setLandingIds] = useState<Map<string, number>>(new Map())
  // Keyed `${unitId}:${affliction}`, valued at the fx.seq that caused it --
  // see StatusBurst.tsx and this effect's own detection below. The seq is
  // there so a REPEAT application (a second burn stacked onto a unit that
  // never lost the first, however rare) remounts the burst by key and plays
  // again, rather than being a no-op update to an already-true boolean.
  const [statusBurstAt, setStatusBurstAt] = useState<Map<string, number>>(new Map())

  // The army's entrance, in two waves -- see REVEAL_STEP_MS/REVEAL_START_MS
  // up top. Keyed by unit id -> its own stagger delay in ms, so the render
  // below only ever needs one number per unit; both waves write into the
  // SAME map (additively, never wholesale-replacing it) since a unit id
  // never appears in both ('h3' is only ever mine or only ever theirs), so
  // there is nothing for the two waves to collide over even if they were
  // ever mid-flight at once.
  const [revealDelays, setRevealDelays] = useState<Map<string, number>>(new Map())
  // Whether each wave's `reveal()` has actually been CALLED yet -- not
  // whether it has finished (that is what `revealDelays` losing an id means)
  // and not whether its effect has merely fired (`mineRevealed`/
  // `theirsRevealed` below already cover scheduling, before the
  // REVEAL_START_MS/VS-screen wait is even over). Jared: "I can see my cards
  // there in the board before I see how they spawn... it should always go
  // from hidden to the animation." Before either flips true, every not-yet-
  // revealed unit in that wave renders `.unit-slot.is-prereveal` (a plain,
  // unconditional opacity: 0 -- see styles.css) so it is invisible from its
  // own very first render, not just from whenever the delayed `reveal()`
  // call happens to attach `.is-landing`. The two flip in the exact same
  // tick `reveal()` itself is called (see below), the same tick
  // `revealDelays` gains that wave's ids, so a unit goes straight from
  // `is-prereveal`'s static opacity: 0 to `is-landing`'s animated one --
  // both zero, so there is nothing to visibly pop between them.
  const [mineStarted, setMineStarted] = useState(false)
  const [theirsStarted, setTheirsStarted] = useState(false)
  // The ground's own wave, ahead of both of the above -- see TILES_DONE_MS
  // et al. up top for the timing and styles.css's `.tile.is-revealing` for
  // what flipping this actually triggers.
  const [tilesStarted, setTilesStarted] = useState(false)
  // Always the current roster, read by the setTimeout callbacks below --
  // which do not themselves re-run on every fx update -- rather than a
  // snapshot from whatever render happened to schedule them.
  const unitsNow = useRef(state.units)
  unitsNow.current = state.units
  // Same reasoning as unitsNow above, for revealTiles()'s own setTimeout
  // callbacks below -- the current obstacles, not whatever render happened
  // to schedule the wave.
  const treesNow = useRef(trees)
  treesNow.current = trees
  const introOpenNow = useRef(introOpen)
  introOpenNow.current = introOpen
  // Latches true the first time `introOpen` is ever seen true, so wave two's
  // "the VS screen just closed" effect below can tell a GENUINE close apart
  // from simply mounting into a render where `introOpen` merely HAPPENS to
  // read false still -- see that effect's own comment for why the
  // distinction matters.
  const introEverOpen = useRef(false)
  if (introOpen) introEverOpen.current = true
  const mineRevealed = useRef(false)
  const theirsRevealed = useRef(false)
  const tilesRevealed = useRef(false)
  // Captured once per match, off whatever `trees` is on this component's
  // very first render of it -- see revealTiles() below and the "initial
  // trees should count in this... animation" ask this exists for. Reset
  // alongside the rest of this match's reveal state in the matchId block
  // just below, off treesNow (not `trees` itself, though they agree on a
  // fresh mount) purely so both reads of "the current obstacles" go
  // through the one ref.
  const initialTreeIds = useRef<Set<string>>(new Set(trees.map((o) => o.id)))

  // A rematch does not remount Board -- Match.tsx keeps this same component
  // mounted and simply points `state` at a new room underneath it (a fresh
  // `matchId`, back at deployment). Without this, `mineRevealed`/
  // `theirsRevealed` are still latched true from the match that just ended,
  // so neither wave below ever fires again for the new one and the next
  // army just appears fully formed, with no entrance at all -- Jared: "when
  // there's a rematch, the animation isn't there anymore."
  //
  // Compared and reset DURING RENDER, not inside a `useEffect` -- the
  // React-sanctioned way to reset state when a prop identifying "which thing
  // is this" changes (the same shape `introEverOpen` above already uses for
  // a ref; `setState` during render is safe too and is what the two pieces
  // of STATE below need, since a ref alone would not be seen by the JSX this
  // same render is about to produce). This way the very first render of the
  // new match already has fresh reveal state, rather than one tick of the
  // old match's stale state before an effect could catch up.
  const prevMatchId = useRef(matchId)
  if (matchId !== prevMatchId.current) {
    prevMatchId.current = matchId
    mineRevealed.current = false
    theirsRevealed.current = false
    tilesRevealed.current = false
    introEverOpen.current = false
    initialTreeIds.current = new Set(treesNow.current.map((o) => o.id))
    if (mineStarted) setMineStarted(false)
    if (theirsStarted) setTheirsStarted(false)
    if (tilesStarted) setTilesStarted(false)
    if (revealDelays.size > 0) setRevealDelays(new Map())
  }

  // Stages one wave: sorts the given units left to right ON SCREEN (for the
  // host that is the mirror of left to right in the state's own x -- the
  // board turns half a turn for the host and nobody else, see
  // flipFor()/draw() above), hands each one its own multiple of
  // REVEAL_STEP_MS, and clears them again once the slowest one has finished
  // its own copy of the structures' `structure-land` animation.
  const reveal = useCallback((units: Unit[]) => {
    if (units.length === 0) return
    const order = [...units].sort((a, b) => {
      const da = draw(a, w, h, flip)
      const db = draw(b, w, h, flip)
      return da.x - db.x || da.y - db.y
    })
    const delays = new Map(order.map((u, i) => [u.id, i * REVEAL_STEP_MS]))
    setRevealDelays((prev) => new Map([...prev, ...delays]))
    const total = LANDING_MS + (order.length - 1) * REVEAL_STEP_MS
    setTimeout(() => {
      setRevealDelays((prev) => {
        const next = new Map(prev)
        for (const id of delays.keys()) next.delete(id)
        return next
      })
    }, total)
  }, [w, h, flip])

  // Flips wave zero and, in the same tick, gives every initial tree its own
  // entrance on the exact diagonal sweep the tiles themselves use --
  // Jared: "initial trees should count in this initial appearing... one by
  // one tile... animation". A second, independent use of .tree.is-landing
  // from the `arrivals` one above: that one is simultaneous by design (a
  // summoner's wall lands all at once, not tile-by-tile) and is untouched;
  // this one is distinguished only by the per-tree --reveal-delay computed
  // here, off the exact same (d.x + d.y) * TILE_REVEAL_STEP_MS formula the
  // tiles themselves use, so a tree settles in exactly when the ground
  // under it does rather than a beat before or after.
  function revealTiles() {
    tilesRevealed.current = true
    setTilesStarted(true)
    const initial = treesNow.current.filter((o) => initialTreeIds.current.has(o.id))
    if (initial.length === 0) return
    const delays = new Map(initial.map((o) => {
      const d = draw(o, w, h, flip)
      return [o.id, (d.x + d.y) * TILE_REVEAL_STEP_MS] as const
    }))
    setLandingIds((prev) => new Map([...prev, ...delays]))
    const maxDelay = Math.max(...delays.values())
    setTimeout(() => {
      setLandingIds((prev) => {
        const next = new Map(prev)
        for (const id of delays.keys()) next.delete(id)
        return next
      })
    }, maxDelay + LANDING_MS)
  }

  // Wave zero: the ground itself. Exactly the same introOpen-gated dance
  // wave two (below) already does -- fire REVEAL_START_MS after mount if
  // the VS screen was never going to show (a reconnect into a match
  // already running), otherwise wait for it to have GENUINELY closed
  // (`introEverOpen` is what tells that apart from simply mounting into a
  // render where `introOpen` still happens to read false -- see wave two's
  // own comment on the distinction). `matchId` rather than a mount-only `[]`
  // so a rematch, which keeps this component mounted and only resets the
  // refs above during render, re-runs this and builds the new board too --
  // Jared already found and fixed this exact gap for the army waves ("when
  // there's a rematch, the animation isn't there anymore").
  useEffect(() => {
    if (tilesRevealed.current) return
    const id = setTimeout(() => {
      if (tilesRevealed.current || introOpenNow.current) return
      revealTiles()
    }, REVEAL_START_MS)
    return () => clearTimeout(id)
  }, [matchId])
  useEffect(() => {
    if (introOpen || !introEverOpen.current || tilesRevealed.current) return
    revealTiles()
  }, [introOpen, matchId])

  // Wave one: your own army -- but not until the ground above has actually
  // finished, which is the part of Jared's original ask this round is
  // fixing: "the board should spawn... right before players see their
  // cards being spawned", not merely start a beat ahead of them while still
  // visibly crossing the board underneath the whole army. `mineCount`
  // rather than `state.units` itself in the dependency array on purpose:
  // `state` is a fresh object reference on effectively every render
  // (Match.tsx recomputes it off a 200ms clock tick even when nothing
  // changed), so depending on it would cancel and reschedule this timer
  // before it ever had a chance to fire. `mineCount > 0` is a plain boolean
  // that only actually changes value once.
  const mineCount = mySide == null ? 0 : state.units.filter((u) => u.owner === mySide).length
  useEffect(() => {
    if (mineRevealed.current || mineCount === 0 || !tilesStarted) return
    mineRevealed.current = true
    const id = setTimeout(() => {
      setMineStarted(true)
      reveal(unitsNow.current.filter((u) => u.owner === mySide))
    }, TILES_DONE_MS + MINE_AFTER_TILES_MS)
    return () => clearTimeout(id)
  }, [mineCount > 0, mySide, reveal, tilesStarted])

  // Wave two: everybody who is not mine -- theirs is fog of war until "all
  // players are ready" hands back the real, combined board, which for a
  // spectator (mySide === null, so "not mine" is everyone) is simply
  // everyone at once. Deferred behind the SAME REVEAL_START_MS Match.tsx's
  // own "should the VS intro show" effect gets to decide `introOpen` --
  // both fire off the same status flip and Board is the CHILD, so its own
  // effects would otherwise run first, in the same commit, and could see
  // `introOpen` still false a moment before Match sets it true. 200ms is far
  // more slack than one extra render needs, and it has the added benefit of
  // never starting wave two before wave one has -- there is no explicit
  // ordering between the two effects below otherwise.
  const theirsCount = state.units.filter((u) => u.owner !== mySide).length
  useEffect(() => {
    if (theirsRevealed.current || theirsCount === 0) return
    const id = setTimeout(() => {
      if (theirsRevealed.current || introOpenNow.current) return
      theirsRevealed.current = true
      setTheirsStarted(true)
      reveal(unitsNow.current.filter((u) => u.owner !== mySide))
    }, REVEAL_START_MS)
    return () => clearTimeout(id)
  }, [theirsCount > 0, mySide, reveal])

  useEffect(() => {
    // NOT just "introOpen is false" -- every effect also runs on mount, and
    // on the very render where `theirsCount` first goes positive, `introOpen`
    // can still read false because Match.tsx has not yet DECIDED to show the
    // VS screen (its own effect, reacting to that same status flip, runs
    // after this one -- Board is the child). Firing here on that stale
    // `false` is exactly the bug Jared reported: wave two went off before
    // the screen even opened, so it was already over by the time the screen
    // covered and then uncovered the board. `introEverOpen` is what tells
    // "never going to show" (handled by the deferred check above instead)
    // apart from "opened, and has NOW genuinely closed" -- only the latter
    // belongs here.
    if (introOpen || !introEverOpen.current || theirsRevealed.current || theirsCount === 0) return
    theirsRevealed.current = true
    setTheirsStarted(true)
    reveal(unitsNow.current.filter((u) => u.owner !== mySide))
  }, [introOpen, theirsCount > 0, mySide, reveal])

  useEffect(() => {
    if (!frozen || queue.length > 0) return
    const left = holdUntil - Date.now()
    if (left <= 0) { setFrozen(null); return }
    const id = setTimeout(() => setFrozen(null), left)
    return () => clearTimeout(id)
  }, [frozen, queue.length, holdUntil])

  const drawnUnits: Unit[] = frozen ? frozen.units : state.units
  const drawnTrees: Obstacle[] = frozen ? frozen.trees : trees

  // useLayoutEffect, not useEffect -- Jared: "why do I see the tokens
  // attacking and the final HP result before the fighting animation?"
  // Exactly the bug a passive effect causes here: `state` (this render's
  // props) already carries the POST-fight HP the instant the server's
  // update lands, and `drawnUnits` below reads `state.units` outright
  // whenever `frozen` is still null from the PREVIOUS exchange having
  // fully resolved -- which it is, the moment a fresh fx first arrives.
  // A useEffect does not run until after the browser has painted that
  // render, so the spoiler (the real, already-decided HP, plus whatever
  // moved) got a real frame on screen before this effect's own setFrozen
  // call below ever masked it again -- the exact "attack happens, THEN
  // the cinematic replays it" order being reported. useLayoutEffect runs
  // synchronously after the DOM update but before the browser paints, so
  // the freeze is already in place for the very first frame anyone sees.
  // Same fix, same reason, as the FLIP slide effect above.
  useLayoutEffect(() => {
    const fx = state.fx
    const prev = before.current
    const priorSeq = lastSeq.current
    before.current = { units: state.units, trees }
    const timers: ReturnType<typeof setTimeout>[] = []

    // A unit gone from the board -- caught here, OUTSIDE the `!fx ||
    // fx.seq === lastSeq.current` bail below, because most of what kills a
    // unit outside cn_attack's own swing loop never moves fx.seq at all (see
    // deathGhosts' own comment up by its useState). This has to run on
    // EVERY render, not only the ones with a fresh fx.
    //
    // A blow this SAME tick's fx already explains gets the precise,
    // exchange-specific ghost below (positioned relative to the attacker,
    // timed with the swing) via `blow` -- excluded here so it is not ALSO
    // given the generic treatment and double-animated. Nothing else that
    // can make a unit vanish from state.units is excluded: the sentence-
    // builder's DEAL_DAMAGE/REFLECT_DAMAGE_PCT/COUNTER_ATTACK_PCT branches
    // in cn_effect_apply_action always pair a unit's removal with cn_bury
    // (see that function's own migration comment -- "called from every
    // place a unit is removed from v_st.units for dying"), and every other
    // rebuild of {units} found in the SQL (cn_attack's own two death
    // branches, the poison/burn turn-start tick, an AoE ability's swing)
    // is the same hp<=0 filter for the same reason. TELEPORT_SELF and
    // SWAP_POSITIONS -- the only mechanics that move a unit without
    // striking it -- edit x/y in place and never drop the unit from the
    // array, so they never reach this diff at all.
    const explainedByFx = new Set<string>()
    if (fx && fx.kind !== 'ability' && fx.seq !== priorSeq) {
      if (fx.killedTgt && fx.tgt) explainedByFx.add(fx.tgt)
      if (fx.killedAtk) explainedByFx.add(fx.atk)
    }
    const liveIds = new Set(state.units.map((u) => u.id))
    const vanished = prev.units.filter((u) => !liveIds.has(u.id) && !explainedByFx.has(u.id))
    if (vanished.length) {
      const seq = ++deathSeq.current
      setDeathGhosts((cur) => [...cur, ...vanished.map((u) => ({ id: u.id, seq, unit: u }))])
      const ids = new Set(vanished.map((u) => u.id))
      timers.push(setTimeout(() => {
        setDeathGhosts((cur) => cur.filter((g) => !ids.has(g.id)))
      }, FX_MS))
    }

    if (!fx || fx.seq === priorSeq) return () => timers.forEach(clearTimeout)
    lastSeq.current = fx.seq

    // A structure that just went up -- any id standing now that was not
    // standing a moment ago, whatever put it there. Diffed by id rather than
    // switched on fx.why/abilityKind on purpose: a summoner's wall today, a
    // scripted structure or a future structures-catalog kind tomorrow all
    // arrive the same way, and the board should not need to be taught each
    // one's name to animate its arrival.
    const priorTreeIds = new Set(prev.trees.map((o) => o.id))
    const arrivals = trees.filter((o) => !priorTreeIds.has(o.id))
    if (arrivals.length) {
      setLandingIds((prev) => new Map([...prev, ...arrivals.map((o) => [o.id, 0] as const)]))
      timers.push(setTimeout(() => {
        setLandingIds((prev) => {
          const next = new Map(prev)
          for (const o of arrivals) next.delete(o.id)
          return next
        })
      }, LANDING_MS))
    }

    // The same diff, for a unit that just picked up an affliction --
    // matched by id against the SAME `prev` snapshot the structure check
    // above uses, and the same reason: whatever caused it (a poison_hit
    // ability, a scripted ON_ATTACK effect riding an ordinary exchange, a
    // structure's own trap), the moment it flips false-to-true is the same
    // moment either way, so it is checked here rather than only inside the
    // ability branch below.
    const newlyAfflicted: string[] = []
    for (const u of state.units) {
      const p = prev.units.find((x) => x.id === u.id)
      if (!p) continue
      if (!isBurning(p) && isBurning(u)) newlyAfflicted.push(`${u.id}:burn`)
      if (!isPoisoned(p) && isPoisoned(u)) newlyAfflicted.push(`${u.id}:poison`)
      if (!isStunned(p) && isStunned(u)) newlyAfflicted.push(`${u.id}:stun`)
    }
    if (newlyAfflicted.length) {
      setStatusBurstAt(new Map(newlyAfflicted.map((k) => [k, fx.seq])))
      timers.push(setTimeout(() => setStatusBurstAt(new Map()), STATUS_BURST_MS))
    }

    const a = prev.units.find((u) => u.id === fx.atk)

    // ---- an ability ---------------------------------------------------------
    // No cinematic: the Duel is two fighters facing each other and an ability
    // is one unit and a crowd. What it gets instead is the board's own
    // language -- a number off every unit it touched -- which is the half that
    // is information rather than performance.
    //
    // And, as of this pass, NO FREEZE either. The hold two blocks down exists
    // to protect a queued Duel cinematic from a spoiler -- reading the result
    // off the bars before the cinematic that is about to explain it has even
    // opened. An ability has no cinematic queued, so there is nothing here for
    // a freeze to protect: it was only ever buying a fixed ~1.3s (FX_MS) of
    // dead air between the ability landing and ANY of it becoming visible --
    // the new wall or bomb, a burn/poison/stun ring lighting up, a bar moving.
    // Jared: "there's this weird [second] delay ... please remove it." Removed
    // for exactly this branch: the board below now draws `state` as it
    // actually stands the instant it arrives, the same way it always has for
    // everything that is not a two-body exchange. The flying hit numbers and a
    // structure's own landing animation (arrivals, above) are the whole of the
    // telling now, played over the real board rather than over a held copy of
    // how it looked a moment ago.
    if (fx.kind === 'ability') {
      setPops(fx.hits ?? [])
      timers.push(setTimeout(() => setPops([]), FX_MS))
      return () => timers.forEach(clearTimeout)
    }

    // Hold the picture at what it was -- reached only for an ordinary
    // exchange now that the ability branch above returns early. FX_MS is the
    // floor even when there is no cinematic to wait for -- with the takeover
    // switched off, the board's own shake and flying numbers are the whole of
    // the telling, and they deserve to happen before the bars move too. An
    // arrival is added to the held picture rather than withheld from it --
    // nothing today makes a structure out of a plain exchange, but if that
    // ever changes this is what keeps it from being hidden behind the hold.
    setFrozen({
      units: prev.units,
      trees: arrivals.length ? [...prev.trees, ...arrivals] : prev.trees,
    })
    setHoldUntil(Date.now() + FX_MS)

    // Past the ability branch, an fx always names a target -- only an ability
    // may have none. Said as a guard rather than asserted with `!`, because
    // the day a third kind of fx arrives this is where it should stop.
    if (fx.tgt == null) return () => timers.forEach(clearTimeout)
    const tgt = prev.units.find((u) => u.id === fx.tgt)
    const wood = prev.trees.find((o) => o.id === fx.tgt)
    if (!a || (!tgt && !wood)) return () => timers.forEach(clearTimeout)

    // `t` is the translator here; the target unit is `tgt`. They were both
    // called t once and that is exactly the kind of collision worth renaming
    // out of existence rather than working around.
    // 'off' means no TAKEOVER, not no feedback: the lunge, the shake and the
    // damage numbers below are the board's own and they stay. What goes is the
    // full-screen retelling, which is the part that is a performance rather
    // than information.
    const mode = getSettings().cine
    if (mode !== 'off') {
      const next = buildCine(fx, fighterOf(a), tgt ? fighterOf(tgt)
        : fighterOfTree(wood!, fighterInfoFor(objKind(wood!), structuresBySlug, t)), t)
      setQueue((q) => [...q, mode === 'quick' ? quicken(next) : next])
    }

    setBlow({
      seq: fx.seq, atk: fx.atk, tgt: fx.tgt,
      dmg: fx.dmg ?? 0, heal: fx.heal ?? 0, counter: fx.counter ?? 0,
      burnAtk: fx.burnAtk ?? 0, burnTgt: fx.burnTgt ?? 0,
      killedTgt: fx.killedTgt, killedAtk: fx.killedAtk,
      atkAt: { x: a.x, y: a.y },
      tgtAt: tgt ? { x: tgt.x, y: tgt.y } : { x: wood!.x, y: wood!.y },
      atkUnit: a, tgtUnit: tgt ?? null,
    })
    // The soundtrack of the exchange used to be scheduled here, against this
    // animation's clock. It belongs to the cinematic now: the cinematic plays
    // the same exchange beat by beat and sounds each one on its own clock, and
    // two soundtracks for one fight is every blow struck twice.
    //
    // The picture below is deliberately NOT moved. It runs under the
    // cinematic, where nobody sees it -- but a player who skips the cinematic
    // two hundred milliseconds in lands on a board that is still resolving the
    // blow, rather than on a board where it has silently already happened.
    timers.push(setTimeout(() => setBlow(null), FX_MS))
    return () => timers.forEach(clearTimeout)
  }, [state])

  const mine = selected && selected.owner === mySide

  const [mode, setMode] = useState<Mode | null>(null)
  // The menu belongs to the selection, so it dies with it -- including when
  // Match drops the selection because the turn flipped under us.
  useEffect(() => { if (!selectedId) setMode(null) }, [selectedId])

  // FRIENDLY FIRE CONFIRMATION. An ordinary attack (not an ability, not a
  // structure -- see clickUnit) on one of your OWN units is intercepted
  // rather than sent straight to onAttack: the id sits here until the
  // player answers the pop-up, and only a Yes calls onAttack. Cleared
  // whenever the selection changes for the same reason `mode` is above --
  // a stale confirmation pointed at a target that is no longer the one
  // selected is a worse bug than the modal simply closing.
  const [confirmAttackId, setConfirmAttackId] = useState<string | null>(null)
  /** A disabled action menu button, clicked/tapped rather than hovered --
   *  see moveDisabledReason/attackDisabledReason/abilityDisabledReason/
   *  defendDisabledReason below for what actually feeds it {title, body}.
   *  Jared: "Explanatory Popups on Click" -- a native `disabled` button eats
   *  the click entirely, which is why the four buttons below no longer carry
   *  the `disabled` attribute and use aria-disabled instead (see .actmenu
   *  button[aria-disabled] in styles.css for the matching greyed-out look). */
  const [explain, setExplain] = useState<{ title: string; body: string } | null>(null)
  useEffect(() => { setConfirmAttackId(null) }, [selectedId])

  // Where the selected unit COULD go, and what it COULD hit. Both are computed
  // whether or not the board is currently showing them, because the menu needs
  // to know whether Move and Attack are worth offering before you pick one --
  // an enabled button that does nothing is worse than a greyed one.
  const canMove = Boolean(selected && mine && isMyTurn && !selected.moved && canAct(state, selected))
  // A cyclone takes the sword, not the feet: a stunned unit may still WALK,
  // so this is on canStrike and deliberately not on canMove. The server
  // refuses both the strike and the ability with the same message; lighting
  // nothing is what stops a player finding that out by being told no.
  const canStrike = Boolean(
    selected && mine && isMyTurn && !selected.acted && canAct(state, selected)
    && !isStunned(selected),
  )

  const litTiles = useMemo(() => {
    if (!selected || !mine) return new Set<string>()
    if (deploying) return deployTiles(state, mySide!)
    if (!canMove) return new Set<string>()
    return reachable(state, selected)
  }, [state, selected, mine, deploying, canMove, mySide])

  const targets = useMemo(() => {
    if (!selected || !mine || deploying || !canStrike) return new Map()
    return targetsFor(state, selected)
  }, [state, selected, mine, deploying, canStrike])

  // WHAT AN ABILITY CAN BE POINTED AT. Three of the five hardcoded kinds
  // take a target, and no two of them take the same set, which is why this
  // is a switch and not the attack's target list with a different name:
  //   heal_any   any unit in reach, ally or enemy, line of sight required
  //   poison_hit enemies only, line of sight required
  //   line_burn  any unit in reach -- a fireball arcs, so no line of sight
  // Lit here so the board can show it; the server decides, as always, and
  // every one of these rules is asserted on that side too.
  //
  // A 'scripted' ability whose ON_ABILITY row targets THE_TARGET is the
  // soft-code sibling of heal_any/poison_hit -- the sentence, not a kind
  // string, says what it may be pointed at: range_kind (CARD_RANGE reads the
  // unit's own rmin/rmax, FIXED_RANGE reads the row's own range_min/max,
  // ANYWHERE skips both range and line of sight) and a `target.is_enemy`
  // condition (see cn_effect_condition_met) for enemies-only, same as
  // poison_hit's own restriction now expressed as data instead of a branch.
  // This client-side copy is a hint, same as summonTiles/scriptTiles below
  // it -- cn_target_in_range on the server is what actually decides.
  const aims = useMemo(() => {
    const out = new Map<string, Target>()
    if (!selected || !mine || deploying || !canStrike) return out
    // awake(), not selected: a Sinie standing next to Umiro has no ability to
    // point anywhere, and lighting targets for one is promising a click the
    // server will refuse.
    const awakeSelected = awake(state, selected)
    const kind = awakeSelected.abilityKind
    if (kind === 'heal_any' || kind === 'poison_hit' || kind === 'line_burn') {
      for (const u of state.units) {
        if (u.id === selected.id) continue
        const d = cheb(selected, u)
        if (d < 1 || d > selected.rmax) continue
        const ally = u.owner === selected.owner
        if (kind === 'poison_hit' && ally) continue
        if (kind !== 'line_burn' && !losClear(state, selected, u)) continue
        out.set(u.id, ally && kind === 'heal_any'
          ? { kind: 'ally', unit: u } : { kind: 'foe', unit: u })
      }
      return out
    }
    if (kind === 'scripted') {
      const row = (awakeSelected.abilityScript ?? [])
        .find((e) => e.trigger === 'ON_ABILITY' && e.target_selector === 'THE_TARGET')
      if (!row) return out
      const anywhere = row.range_kind === 'ANYWHERE'
      const fixed = row.range_kind === 'FIXED_RANGE'
      const rmin = fixed ? (row.range_min ?? 1) : (selected.rmin ?? 1)
      const rmax = fixed ? (row.range_max ?? selected.rmax) : selected.rmax
      const enemyOnly = mentionsEnemyOnly(row.conditions ?? [])
      for (const u of state.units) {
        if (u.id === selected.id) continue
        if (!anywhere) {
          const d = cheb(selected, u)
          if (d < rmin || d > rmax) continue
          if (!losClear(state, selected, u)) continue
        }
        const ally = u.owner === selected.owner
        if (enemyOnly && ally) continue
        out.set(u.id, ally ? { kind: 'ally', unit: u } : { kind: 'foe', unit: u })
      }
      return out
    }
    return out
  }, [state, selected, mine, deploying, canStrike])

  // WHERE A SUMMONER MAY PUT SOMETHING. A tile rather than a unit, which is
  // the one thing the ability menu has never had to point at before -- Mako's
  // trap, Fey's wall and Lumea's tornado all land on empty ground. Mirrors the
  // summon branch of cn_ability: in reach, line of sight clear, nothing
  // standing there and nothing already lying there.
  const summonTiles = useMemo(() => {
    const out = new Set<string>()
    if (!selected || !mine || deploying || !canStrike) return out
    if (awake(state, selected).abilityKind !== 'summon') return out
    // One alive at a time is not a cooldown: it is "is the last one still
    // there", and the answer is on the board rather than on the unit.
    if ((state.obstacles ?? []).some((o) => o.by === selected.id)) return out
    const taken = occupied(state)
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const d = cheb(selected, { x, y })
        if (d < 1 || d > selected.rmax) continue
        if (taken.has(key(x, y))) continue
        if (!losClear(state, selected, { x, y })) continue
        out.add(key(x, y))
      }
    }
    return out
  }, [state, selected, mine, deploying, canStrike, w, h])

  // LUMEA'S FIFTEEN SECONDS. A decision belonging to the side whose turn it is
  // NOT, which is the one shape this board has never drawn. While it is open
  // the server refuses everything, so the board offers nothing either -- the
  // menu is gone and the only lit tiles are the ones the gale can reach.
  const pending = state.pending ?? null
  const caught = pending ? state.units.find((u) => u.id === pending.unit) ?? null : null
  const throwing = Boolean(pending && caught && pending.side === mySide && !watching(mySide))

  const throwTiles = useMemo(() => {
    const out = new Set<string>()
    if (!throwing || !caught) return out
    const bodies = new Set(state.units.map((u) => key(u.x, u.y)))
    const walls = new Set((state.obstacles ?? [])
      .filter((o) => objSolid(objKind(o))).map((o) => key(o.x, o.y)))
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const d = cheb(caught, { x, y })
        // No line of sight: a gale throws OVER things. What it cannot do is
        // put somebody inside a wall or on top of another unit -- and a trap
        // is neither, which is exactly where you want to aim.
        if (d < 1 || d > THROW_REACH) continue
        if (bodies.has(key(x, y)) || walls.has(key(x, y))) continue
        out.add(key(x, y))
      }
    }
    return out
  }, [throwing, caught, state, w, h])

  // WHERE A SCRIPTED ACTIVE ABILITY MAY BE POINTED, since 0056. Every
  // OTHER target_selector a card_effects row can carry (SELF, ALL_ENEMIES,
  // NEAREST_ENEMY, LOWEST_HP_ALLY...) is resolved entirely server-side by
  // cn_resolve_targets from the selector alone -- the client supplies no
  // target for those, exactly like aoe_adjacent/mist below. BOARD_CELL is
  // the one exception: the same '@x,y' tile convention CREATE_STRUCTURE and
  // TELEPORT_SELF already use, so a scripted ability whose ON_ABILITY row
  // targets BOARD_CELL needs a tile clicked first, the same shape summonTiles
  // already draws for the six hardcoded kinds' own summon branch.
  const scriptTiles = useMemo(() => {
    const out = new Set<string>()
    if (!selected || !mine || deploying || !canStrike) return out
    const awakeSelected = awake(state, selected)
    if (awakeSelected.abilityKind !== 'scripted') return out
    const row = (awakeSelected.abilityScript ?? []).find((e) => e.trigger === 'ON_ABILITY')
    if (!row || row.target_selector !== 'BOARD_CELL') return out
    // Mirrors cn_create_structure's own "(a) one live structure per unit at
    // a time" guard (0064) -- the client had this for the old hardcoded
    // 'summon' kind (see summonTiles above) but never grew it when Fey,
    // Mako and Lumea moved onto this soft-coded CREATE_STRUCTURE path in
    // that same migration, so a player could see tiles lit for a placement
    // the server was always going to refuse. TELEPORT_SELF (the row's other
    // live BOARD_CELL action) carries no such limit, so this is scoped to
    // the two structure-placing action names specifically.
    if (
      (row.action === 'CREATE_STRUCTURE' || row.action === 'SUMMON_OBJECT')
      && (state.obstacles ?? []).some((o) => o.by === selected.id)
    ) return out
    const taken = occupied(state)
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const d = cheb(selected, { x, y })
        if (d < 1 || d > selected.rmax) continue
        if (taken.has(key(x, y))) continue
        if (!losClear(state, selected, { x, y })) continue
        out.add(key(x, y))
      }
    }
    return out
  }, [state, selected, mine, deploying, canStrike, w, h])

  /** A 'scripted' ability whose sentence does NOT target BOARD_CELL or
   *  THE_TARGET needs no click at all -- see scriptTiles' and aims' own
   *  comments for what each of those two rows means. */
  const scriptAimless = selected?.abilityKind === 'scripted'
    && !(awake(state, selected).abilityScript ?? []).some((e) => e.trigger === 'ON_ABILITY'
      && (e.target_selector === 'BOARD_CELL' || e.target_selector === 'THE_TARGET'))

  /** Is the selected unit standing in somebody's marsh? */
  const selectedSwamped = Boolean(selected && isSwamped(state, selected))

  /** Does this unit's ability need something clicked before it fires? */
  const aimed = selected?.abilityKind === 'heal_any'
    || selected?.abilityKind === 'poison_hit'
    || selected?.abilityKind === 'line_burn'
    || selected?.abilityKind === 'summon'
    || (selected?.abilityKind === 'scripted' && !scriptAimless)

  /** Can this unit use its ability at all, right now? */
  // 0056: uses/cooldown for a scripted Active ability, read straight off
  // the unit snapshot -- see Unit.abilityMaxUses's own comment. Mirrors
  // cn_ability's own check exactly (same >=/<=, same "coalesce to 1"
  // opening-turn treatment as actsCap) so the button goes dim at the same
  // moment the server would refuse it, rather than a click round-tripping
  // to a rejection the menu could have shown instead.
  const abilityUsesLeft = selected?.abilityMaxUses != null
    ? Math.max(0, selected.abilityMaxUses - (selected.abilityUses ?? 0))
    : null
  const abilityCooldownLeft = (() => {
    const cd = selected?.abilityCooldownTurns
    const last = selected?.abilityLastUsedTurn
    if (!cd || last == null) return 0
    const now = state.turnNumber ?? 1
    return Math.max(0, cd - (now - last))
  })()
  const abilityOutOfUses = abilityUsesLeft === 0
  const abilityOnCooldown = abilityCooldownLeft > 0

  const canAbility = Boolean(
    selected && mine && isMyTurn && selected.abilityKind && !selected.acted
    && canAct(state, selected) && !isStunned(selected) && !selectedSwamped
    && !abilityOutOfUses && !abilityOnCooldown
    && (!aimed || aims.size > 0 || summonTiles.size > 0 || scriptTiles.size > 0),
  )

  // WHY the menu's four real actions are dim, in words rather than a boolean --
  // "Action Availability, Visual Disabling & Explanatory Popups": Jared asked
  // for a click/tap on a disabled button to say why, with the two concrete
  // wordings below for a summoner with nowhere to put what it makes. Each
  // reason mirrors its button's own can-do boolean case for case (canMove,
  // canStrike, canAbility above) rather than re-deriving a fresh judgement,
  // so the popup can never disagree with why the button actually went grey.
  // undefined means the button is enabled and there is nothing to explain.
  const moveDisabledReason = !canMove
    ? (selected?.moved ? t('board.moveAlreadyMoved') : t('board.actSpent'))
    : litTiles.size === 0 ? t('board.moveNoSpace')
    : undefined

  // Shared by Attack and Defend -- both live and die by canStrike, and a
  // stunned or already-acted unit is refused the same way for either one.
  const strikeBlockedReason = !canStrike
    ? (selected && isStunned(selected) ? t('board.stunned')
       : selected?.acted ? t('board.actAlreadyActed')
       : t('board.actSpent'))
    : undefined
  const attackDisabledReason = strikeBlockedReason
    ?? (targets.size === 0 ? t('board.attackNoTarget') : undefined)
  const defendDisabledReason = strikeBlockedReason

  // What the row this ability's ON_ABILITY trigger lives on would actually
  // do, purely to tell "no empty tile for the thing I am placing" apart from
  // "no valid target for the thing I am pointing at" -- summonTiles/aims/
  // scriptTiles above already know which one applies, this just names it.
  const scriptRow = selected && selected.abilityKind === 'scripted'
    ? (awake(state, selected).abilityScript ?? []).find((e) => e.trigger === 'ON_ABILITY') ?? null
    : null
  const isStructureAbility = selected?.abilityKind === 'summon'
    || scriptRow?.action === 'CREATE_STRUCTURE' || scriptRow?.action === 'SUMMON_OBJECT'
  const structureAlreadyActive = Boolean(
    selected && (state.obstacles ?? []).some((o) => o.by === selected.id),
  )
  const abilityDisabledReason = !selected ? undefined
    : !selected.abilityKind ? t('board.abilityPassive')
    : selectedSwamped ? t('board.abilitySwamped')
    : isStunned(selected) ? t('board.stunned')
    : abilityOutOfUses ? t('board.abilityNoUses')
    : abilityOnCooldown ? t('board.abilityCooldown', { turns: abilityCooldownLeft })
    : (aimed && aims.size === 0 && summonTiles.size === 0 && scriptTiles.size === 0)
      ? (isStructureAbility
          ? (structureAlreadyActive ? t('board.abilityStructureActive') : t('board.abilityNoSpace'))
          : t('board.abilityNoTarget'))
      : !canAbility ? t('board.actSpent')
      : undefined

  /**
   * Abilities that hit nowhere in particular go straight off the menu.
   *
   * The targetless kinds are named POSITIVELY -- Back to Back and the Mist,
   * and nothing else -- rather than being "whatever `aimed` is not. A client
   * that meets an ability kind it has never heard of must do nothing, because
   * the alternative is what it used to do: fire with a null target and let the
   * server answer 'that ability needs a tile' to a player who was never
   * offered one.
   */
  const fireAbility = () => {
    if (!selected) return
    if (aimed) { setMode('ability'); return }
    const k = selected.abilityKind
    if (k !== 'aoe_adjacent' && k !== 'mist' && k !== 'scripted') { setMode(null); return }
    onAbility(selected.id, null)
    setMode(null)
  }

  // And what the board actually draws. In deployment there is no menu -- you
  // are placing, not activating -- so the tiles are lit the moment you pick
  // something up, exactly as they always were.
  const showTiles = deploying || mode === 'move'
  const showTargets = !deploying && mode === 'attack'
  const showAims = !deploying && mode === 'ability'
  // In ability mode a summoner lights GROUND, not units, and it is the same
  // lit-tile channel the move menu uses -- so clickTile below has to know
  // which of the two it is answering.
  const shownTiles = throwing ? throwTiles
    : showTiles ? litTiles
    : showAims ? (summonTiles.size ? summonTiles : scriptTiles) : new Set<string>()
  const shownTargets = showTargets ? targets : showAims ? aims : new Map()

  // Which way a piece leans when it swings. Drawn direction again, for the
  // same reason the travel above is: half a turn of the board turns a lunge
  // north into a lunge south.
  // Which tile the pointer is over, in BOARD coordinates.
  //
  // One handler on the board rather than one per tile, because it has to keep
  // reporting while the pointer is over a unit or a tree as well -- those sit
  // in the cells, on top of them, and a tile's own mouseenter never fires
  // under them. Reading the position off the board's rect and its real tile
  // pitch costs one getBoundingClientRect per move and gets the answer right
  // over anything that happens to be standing there.
  //
  // Only ever set when the tile CHANGES, so a pointer wandering inside one
  // square does not re-render the board sixty times a second.
  const [overTile, setOverTile] = useState<{ x: number; y: number } | null>(null)
  const boardRef = useRef<HTMLDivElement | null>(null)

  function trackPointer(e: React.PointerEvent<HTMLDivElement>) {
    const el = boardRef.current
    if (!el) return
    const r = el.getBoundingClientRect()
    const gs = getComputedStyle(el)
    const gapX = parseFloat(gs.columnGap) || 0
    const gapY = parseFloat(gs.rowGap) || 0
    const pitchX = (r.width + gapX) / w
    const pitchY = (r.height + gapY) / h
    const dx = Math.floor((e.clientX - r.left) / pitchX)
    const dy = Math.floor((e.clientY - r.top) / pitchY)
    if (dx < 0 || dy < 0 || dx >= w || dy >= h) { setOverTile(null); return }
    // Drawn tile back to a board tile. draw() is its own inverse, which is
    // what undraw() is saying out loud.
    const b = undraw({ x: dx, y: dy }, w, h, flip)
    setOverTile((prev) => (prev && prev.x === b.x && prev.y === b.y ? prev : b))
  }

  // The route the selected unit would walk to the tile under the pointer.
  // Only while Move is the open question: an arrow drawn at any other moment
  // is a promise about a click that would not move anything.
  const arrow = useMemo(() => {
    if (!selected || !showTiles || deploying || !overTile) return null
    if (!shownTiles.has(key(overTile.x, overTile.y))) return null
    return pathTo(state, selected, overTile.x, overTile.y)
  }, [state, selected, showTiles, deploying, overTile, shownTiles])

  // Tell the other side where we are looking. Driven off an effect rather
  // than the pointer handler so that picking a unit or opening Attack is
  // reported too -- those change what you are about to do without the pointer
  // having moved at all.
  useEffect(() => {
    // The opponent's pointer shows a crosshair for aiming of either kind:
    // they can see you are pointing at something, not what you will do
    // with it, which is the same thing an attack tells them.
    onLook?.({ tile: overTile, unit: selectedId, mode: mode === 'ability' ? 'attack' : mode })
  }, [overTile, selectedId, mode, onLook])

  // And what to draw of theirs. The highlights are RECOMPUTED here rather than
  // sent: the board is public, the rules are in rules.ts, and three small
  // fields down the wire beat a list of tiles that would go stale in flight.
  // Gated the same way ours are, so their ghost never shows a go they have
  // already spent.
  const theirs = useMemo(() => {
    const gu = ghost?.unit ? state.units.find((u) => u.id === ghost.unit) : null
    if (!gu || gu.owner === mySide) return { unit: null, tiles: new Set<string>(), aims: new Set<string>() }
    const tiles = ghost?.mode === 'move' && !gu.moved ? reachable(state, gu) : new Set<string>()
    const aims = ghost?.mode === 'attack' && !gu.acted
      ? new Set(targetsFor(state, gu).keys()) : new Set<string>()
    return { unit: gu, tiles, aims }
  }, [ghost, state, mySide])

  // Their floating destination arrow -- the same picture `arrow` above draws
  // for a move of your own, just walked from their unit to the tile their
  // pointer is over. Jared: "their floating destination arrows must be
  // visible in real time... mirroring how a player sees their own movement
  // arrows when selecting Move." `ghost.tile` is already the tile their
  // pointer is on (see the onLook effect above); gating on `theirs.tiles`
  // means a stale or lagging ghost tile that is no longer reachable (their
  // board moved on since the packet was sent) simply draws nothing rather
  // than a route that lies about where the unit could actually go.
  const theirArrow = useMemo(() => {
    if (!theirs.unit || ghost?.mode !== 'move' || !ghost.tile) return null
    if (!theirs.tiles.has(key(ghost.tile.x, ghost.tile.y))) return null
    return pathTo(state, theirs.unit, ghost.tile.x, ghost.tile.y)
  }, [theirs, ghost, state])

  // Where the menu hangs, in drawn coordinates. Null when there is no menu.
  // No menu while a decision is open: there is nothing on it the server would
  // accept, and a menu of five greyed-out buttons is worse than no menu.
  const menuAt = mode === 'menu' && selected && !pending ? draw(selected, w, h, flip) : null

  const lungeVars = (from: { x: number; y: number }, to: { x: number; y: number }) =>
    ({
      '--lx': `${drawSign(flip) * Math.sign(to.x - from.x) * 16}%`,
      '--ly': `${drawSign(flip) * Math.sign(to.y - from.y) * 16}%`,
    }) as React.CSSProperties

  /** Clicking one of yours opens its menu -- unless it has nothing left to
   *  spend, in which case the click still selects it so you can read the card,
   *  it just does not offer you a go it would have to refuse. */
  const opensMenu = (u: Unit) =>
    !deploying && isMyTurn && u.owner === mySide && canAct(state, u) && !state.winner

  function pick(u: Unit) {
    if (u.id !== selectedId) playSelect()
    onSelect(u.id)
    setMode(opensMenu(u) ? 'menu' : null)
  }

  function clickTile(x: number, y: number) {
    // `frozen` means an exchange is currently being held/told on screen --
    // see the `onWatching` effect's comment above for why this must block
    // clicks too, not just gate the bot, or the player's own next click can
    // be the very thing that fires a second action before the first one's
    // cinematic ever gets queued.
    if (locked || watching(mySide) || frozen) return
    // A decision outranks everything: it is the only thing the server will
    // accept, so it is the only thing the board offers.
    if (throwing) {
      if (throwTiles.has(key(x, y))) onThrow?.(`@${x},${y}`)
      return
    }
    if (pending) return
    if (deploying) {
      // Placing one ends the placing. Leaving the unit selected left its whole
      // half lit up as if you still had something in your hand, which is only
      // true until you put it down.
      if (selected && mine && shownTiles.has(key(x, y))) { onDeploy(selected.id, x, y); onSelect(null) }
      else onSelect(null)
      return
    }
    // Walking does not end the go: the unit may still strike, and move-then-
    // strike is one activation. So the menu comes straight back, standing
    // where the unit now stands, with Move spent and the rest still there.
    if (showAims) {
      // '@x,y' is the wire format 0035 introduced for a target that is a tile
      // rather than a unit. cn_tile_target() is the only thing that reads it.
      if (summonTiles.has(key(x, y))) { onAbility(selectedId!, `@${x},${y}`) }
      else if (scriptTiles.has(key(x, y))) { onAbility(selectedId!, `@${x},${y}`) }
      setMode(null)
      return
    }
    if (shownTiles.has(key(x, y))) { onMove(x, y); setMode('menu') }
    else { onSelect(null); setMode(null) }
  }

  function clickUnit(u: Unit) {
    if (locked || watching(mySide) || frozen) return
    // Same rule as clickTile: while a decision is open the gale is the only
    // thing anybody may answer, and it is answered by clicking GROUND.
    if (pending) return
    if (deploying) {
      // Dropping one of yours onto another of yours swaps the pair.
      if (selected && mine && u.owner === mySide && u.id !== selected.id) {
        onDeploy(selected.id, u.x, u.y)
        onSelect(null)
      } else { if (u.id !== selectedId) playSelect(); onSelect(u.id === selectedId ? null : u.id) }
      return
    }
    // Aiming. Attacking has its own sound a moment later, from the exchange;
    // putting one here as well would double every blow.
    if (shownTargets.has(u.id)) {
      if (showAims) { onAbility(selectedId!, u.id); setMode(null); return }
      // FRIENDLY FIRE CONFIRMATION. 0038 allows striking your own -- an
      // ally in reach is an ordinary target, same as a foe -- so a
      // misclick two tiles from your own crown is one careless tap away
      // from losing the match. targetsFor/rules.ts already tells us this
      // is 'ally' (one of yours); an 'ability' aimed at an ally (heal_any
      // and friends) is untouched -- this is only the plain-strike path.
      const tgt = shownTargets.get(u.id)
      if (tgt?.kind === 'ally') { setConfirmAttackId(u.id); return }
      onAttack(u.id)
      setMode(null); return
    }
    // Clicking the open menu's own unit closes it, which is the second way out
    // besides Cancel and the one a thumb finds first.
    if (u.id === selectedId && mode) { setMode(null); return }
    pick(u)
  }

  // The tinted half is always the NEAR one -- which for a player is their own,
  // because the flip has already put them at the bottom. A spectator turns
  // nothing, so the near half of their board is the guest's, and tinting it is
  // the honest reading: it says "this end", not "yours", and there is nothing
  // that is theirs to say.
  const halfSide: Side = mySide ?? 'guest'

  return (
    <>
    <div
      ref={boardRef}
      onPointerMove={trackPointer}
      onPointerLeave={() => setOverTile(null)}
      className={`board${blow ? ' fx-playing' : ''}${watching(mySide) ? ' is-watching' : ''}`}
      style={{ '--cols': w, '--rows': h } as React.CSSProperties}
      onClick={() => { onSelect(null); setMode(null) }}
    >
      {Array.from({ length: w * h }, (_, i) => {
        const x = i % w
        const y = Math.floor(i / w)
        const k = key(x, y)
        const lit = shownTiles.has(k)
        // Screen-space corner, not board-space: draw() already accounts for
        // the flip, so this is "upper-left as the player actually sees it"
        // on both sides of the board.
        const d = draw({ x, y }, w, h, flip)
        return (
          <div
            key={k}
            // Explicit placement, not auto-flow: everything else on this grid
            // is placed by coordinate, and CSS grid positions definite items
            // first, so auto-flowed tiles would be pushed off the end.
            style={{
              ...at({ x, y }),
              '--tile-delay': `${(d.x + d.y) * TILE_REVEAL_STEP_MS}ms`,
            } as React.CSSProperties}
            className={[
              'tile',
              // Gated on tilesStarted rather than unconditional -- see
              // TILES_DONE_MS et al. and the wave-zero effects up top for
              // why the board no longer builds itself the instant it mounts.
              tilesStarted ? 'is-revealing' : '',
              ownSide(halfSide, y, h) ? 'tile-mine' : 'tile-theirs',
              lit ? (deploying ? 'tile-deploy'
                    : (showAims || throwing) ? 'tile-aim' : 'tile-move') : '',
              theirs.tiles.has(k) ? 'tile-theirlook' : '',
            ].join(' ')}
            onClick={(e) => { e.stopPropagation(); clickTile(x, y) }}
          />
        )
      })}

      {drawnTrees.map((t) => (
        <Thing
          key={t.id}
          thing={t}
          style={at(t)}
          mine={t.owner == null ? null : t.owner === mySide}
          targetable={shownTargets.has(t.id)}
          shaking={blow?.tgt === t.id}
          falling={blow?.tgt === t.id && blow.killedTgt}
          landing={landingIds.has(t.id)}
          landingDelayMs={landingIds.get(t.id)}
          prereveal={initialTreeIds.current.has(t.id) && !tilesStarted}
          onHover={(over) => onHover(over ? t.id : null)}
          onPeek={() => onPeek?.(t.id)}
          onClick={(e) => {
            e.stopPropagation()
            if (shownTargets.has(t.id)) {
              if (showAims) onAbility(selectedId!, t.id); else onAttack(t.id)
              setMode(null)
            }
            // BUG FIX: a non-solid obstacle (a trap, a tornado, or any
            // custom structure with blocks_movement=false -- a "steppable"
            // one) sits in the SAME cell as the tile underneath it, drawn
            // on top of it, so it used to swallow every click meant for
            // that tile: move, throw and ability-placement all fell into
            // the `else` below and simply deselected instead of reaching
            // clickTile. reachable()/cn_reach already agree the tile is
            // walkable -- this was purely a click ROUTING bug, never a
            // rule one, which is why units could not be walked onto their
            // own (or an enemy's) steppable structures even though the
            // server would have allowed it. Delegating to clickTile with
            // this thing's own coordinates gives every one of its cases
            // (move, throw-aim, summon/script tile) the exact same click
            // the bare tile underneath would have handled.
            else { clickTile(t.x, t.y) }
          }}
        />
      ))}

      {drawnUnits.map((u) => {
        const striking = blow?.atk === u.id
        const struck = blow?.tgt === u.id
        const target = shownTargets.get(u.id)
        // Whichever afflictions just landed on THIS unit this exchange --
        // almost always at most one, but a scripted ability naming several
        // effects on one ON_ABILITY row is not impossible, so this is a
        // list rather than an either/or.
        const statusBursts = (['burn', 'poison', 'stun'] as const)
          .map((kind) => ({ kind, seq: statusBurstAt.get(`${u.id}:${kind}`) }))
          .filter((b): b is { kind: Affliction; seq: number } => b.seq != null)
        return (
          <UnitCard
            key={u.id}
            unit={u}
            slot={at(u)}
            yours={mySide !== null && u.owner === mySide}
            watching={watching(mySide)}
            selected={u.id === selectedId}
            target={target ? target.kind : null}
            counters={target ? willCounterOn(state, selected!, target) : false}
            caught={pending?.unit === u.id}
            swamped={isSwamped(state, u)}
            mendable={Boolean(selected?.heals)}
            // A burst only where something LANDED. A lunge that missed, a
            // mend, and a unit merely standing next to the fight all get
            // nothing: particles that fire on every exchange stop meaning
            // "that hurt" and start meaning "an exchange happened".
            burst={struck && (blow?.dmg ?? 0) > 0 ? blow!.seq : 0}
            statusBursts={statusBursts}
            slotClass={[
              striking ? 'fx-strike' : '',
              struck && !blow?.killedTgt && !blow?.heal ? 'fx-hurt' : '',
              struck && blow!.heal > 0 ? 'fx-mend' : '',
              struck && blow!.counter > 0 ? 'fx-strike-late' : '',
              striking && blow!.counter > 0 && !blow!.killedAtk ? 'fx-hurt-late' : '',
              revealDelays.has(u.id) ? 'is-landing' : '',
              // Hidden from its OWN first render, not just from whenever the
              // delayed reveal() call happens to reach it -- see
              // mineStarted/theirsStarted above.
              !revealDelays.has(u.id) && (u.owner === mySide ? !mineStarted : !theirsStarted)
                ? 'is-prereveal'
                : '',
            ].join(' ')}
            slotVars={
              striking && blow
                ? lungeVars(blow.atkAt, blow.tgtAt)
                : struck && blow
                  ? lungeVars(blow.tgtAt, blow.atkAt)
                  : revealDelays.has(u.id)
                    ? ({
                        '--landing-ms': `${LANDING_MS}ms`,
                        '--reveal-delay': `${revealDelays.get(u.id)}ms`,
                      } as React.CSSProperties)
                    : undefined
            }
            onHover={(over) => onHover(over ? u.id : null)}
            onPeek={() => onPeek?.(u.id)}
            slotRef={(el) => { if (el) slots.current.set(u.id, el); else slots.current.delete(u.id) }}
            onClick={(e) => { e.stopPropagation(); clickUnit(u) }}
          />
        )
      })}

      {/* Them. A pale echo of the board they are looking at: the tile under
          their pointer, a ring round the unit they have picked up, and a mark
          on whatever they are lining it up to hit. Nothing here is a fact about
          the match -- it is a fact about a pointer, and it goes the moment they
          move it. See useGhost.ts for what deliberately never reaches it. */}
      {ghost?.tile && (
        <div className="ghosttile" style={at(ghost.tile)} aria-hidden="true">
          <i />
        </div>
      )}
      {theirs.unit && (
        <div className="ghostsel" style={at(theirs.unit)} aria-hidden="true" />
      )}
      {[...theirs.aims].map((id) => {
        const t = state.units.find((u) => u.id === id)
          ?? (state.obstacles ?? []).find((o) => o.id === id)
        return t ? <div key={id} className="ghostaim" style={at(t)} aria-hidden="true" /> : null
      })}

      {/* The movement route, one triangle per tile rather than one line across
          the board -- still Fire Emblem's trick, just not its shape any more.
          Every piece is an ordinary grid item in its own cell, so it needs no
          pixel arithmetic and cannot drift when the board is resized.
          Purely a picture of what clicking would do; the click itself is the
          tile's, underneath.

          It used to be a segmented arrow (ArrowPart, defined below until
          this pass replaced it with MoveTriangle) built out of exactly four
          edges -- n/s/e/w -- because
          movement itself only ever went in four directions. 0076 taught
          movement to step diagonally and this stayed built for the old
          world: side() asked only "is the next tile north, south, east or
          west of this one", so a diagonal step (nonzero on BOTH axes) always
          answered north/south and ignored east/west entirely, which is
          exactly the floating, disconnected pieces Jared saw once a route
          ever turned a corner. A triangle rotated by the plain angle between
          two tiles has no such blind spot -- north, east, and the four
          corners between them are all just a number of degrees, not a case
          that has to be listed and gets forgotten. */}
      {/* THE TAIL STARTS AT THE SECOND TILE, not the first. The first tile of
          a route is the one the unit is standing on, and the unit is drawn
          over it at a higher z-index than the arrow -- so everything this
          loop used to put there (a dot and half a shaft) was painted
          underneath the piece and never seen. Jared: "sometimes I can't see
          its tail". Starting at i = 1 makes the tail the shaft entering from
          the edge it shares with the unit, which is visible, and is how every
          game that draws these does it. */}
      {arrow && arrow.length > 1 && selected && arrow.slice(1).map((p, j) => {
        const i = j + 1
        return (
          <MoveTriangle
            key={`${p.x},${p.y}`}
            style={at(p)}
            angle={angleTo(draw(arrow[i - 1], w, h, flip), draw(p, w, h, flip))}
            role={selected.role}
            delayMs={j * 90}
          />
        )
      })}

      {/* Theirs. Same triangles, same colour, same float -- the request was
          literally to mirror your own arrow, not to invent a second look for
          it -- just faded a touch (see .movearrow.is-ghost) so the one thing
          that IS different about it, that it is not a fact yet, still reads
          at a glance. */}
      {theirArrow && theirArrow.length > 1 && theirs.unit && theirArrow.slice(1).map((p, j) => {
        const i = j + 1
        return (
          <MoveTriangle
            key={`ghost-${p.x},${p.y}`}
            style={at(p)}
            angle={angleTo(draw(theirArrow[i - 1], w, h, flip), draw(p, w, h, flip))}
            role={theirs.unit!.role}
            delayMs={j * 90}
            ghost
          />
        )
      })}

      {/* THE GALE. One strip over the board, because the decision belongs to
          the player rather than to any one piece and there is no menu open to
          hang it off. It says the same thing to both sides in different words:
          one of them is choosing, the other is waiting, and neither may do
          anything else. The countdown is the ordinary turn clock -- while a
          decision is open that clock IS the decision's, which is the whole
          reason 0036 did not add a second one. */}
      {pending && caught && (
        <div
          className={`galebar${throwing ? ' is-yours' : ''}`}
          role="status"
          // Away from the piece, the same way the action menu opens away from
          // the nearest edge: the tiles you are choosing among are the ones
          // within three of the caught unit, and a strip sitting on top of
          // them is a strip in the way of the only click that matters.
          style={{ gridRow: draw(caught, w, h, flip).y > (h - 1) / 2 ? 1 : h,
                   alignSelf: draw(caught, w, h, flip).y > (h - 1) / 2 ? 'start' : 'end' }}
        >
          <span className="galebar-glyph" aria-hidden="true">
            <ThingGlyph kind="tornado" />
          </span>
          <b>
            {throwing
              ? t('throw.choose', { name: caught.name })
              : t('throw.waiting', { name: caught.name })}
          </b>
          {throwing && (
            <button type="button" onClick={() => onThrow?.(null)}>
              {t('throw.leave')}
            </button>
          )}
        </div>
      )}

      {/* The action menu. Anchored to the tile the unit is standing on and
          drawn over the board rather than beside it, so your eye never leaves
          the piece you are giving an order to.
          It opens away from the nearest edge -- leftward from the right-hand
          columns, upward from the bottom rows -- because .center clips what
          overflows it, and a menu half off the screen is a menu you cannot
          finish using. Those are DRAWN columns, so the rule holds either way
          up the board is turned. */}
      {menuAt && selected && (
        <div className="actmenu-slot" style={at(selected)}>
          <div
            className={[
              'actmenu',
              menuAt.x > (w - 1) / 2 ? 'is-left' : '',
              menuAt.y > (h - 1) / 2 ? 'is-up' : '',
            ].join(' ')}
            role="menu"
            aria-label={t('board.chooseAction', { name: selected.name })}
            onClick={(e) => e.stopPropagation()}
          >
            <div className="actmenu-head">{selected.name}</div>
            {/* Four of these five used to carry the `disabled` attribute,
                which is exactly the problem: a disabled button swallows the
                click before React ever sees it, so there was no way to tell
                a player WHY short of a hover title that a thumb on glass
                never triggers. aria-disabled keeps the same greyed-out look
                (see .actmenu button[aria-disabled] in styles.css) but leaves
                the click live -- the handler below checks the reason itself
                and either opens the explanatory popup or does the real
                thing, never both. */}
            <button
              role="menuitem"
              aria-disabled={Boolean(moveDisabledReason)}
              title={moveDisabledReason}
              onClick={() => {
                if (moveDisabledReason) { setExplain({ title: t('board.move'), body: moveDisabledReason }); return }
                setMode('move')
              }}
            >
              <span className="actmenu-icon actmenu-icon-move"><IconArrowUp /></span>
              {t('board.move')}
            </button>
            <button
              role="menuitem"
              aria-disabled={Boolean(attackDisabledReason)}
              title={attackDisabledReason}
              onClick={() => {
                if (attackDisabledReason) {
                  setExplain({
                    title: t(selected.heals ? 'board.strikeMend' : 'board.attack'),
                    body: attackDisabledReason,
                  })
                  return
                }
                setMode('attack')
              }}
            >
              <span className="actmenu-icon actmenu-icon-attack"><IconSword /></span>
              {t(selected.heals ? 'board.strikeMend' : 'board.attack')}
            </button>
            {/* On at last. The slot has been here since Phase C, deliberately
                empty, so that switching it on would not move the other four
                items under the player's thumb. Off still, for a unit whose
                card carries a passive rather than an ability -- with a
                different reason said in the tooltip, because "not yet" and
                "not this card" are not the same news. */}
            <button
              role="menuitem"
              aria-disabled={Boolean(abilityDisabledReason)}
              // Seven different pieces of news now, not three -- 0056 added
              // uses-left and cooldown, and this pass added "nowhere to put
              // it" and "one is already out there" for a summoner with no
              // valid tile left -- a player who cannot tell them apart will
              // think the game is broken rather than that they are out of
              // uses this match, or standing on the wrong side of the board.
              title={abilityDisabledReason}
              onClick={() => {
                if (abilityDisabledReason) {
                  setExplain({ title: t('board.ability'), body: abilityDisabledReason })
                  return
                }
                fireAbility()
              }}
            >
              <span className="actmenu-icon actmenu-icon-ability"><IconRhombus /></span>
              {t('board.ability')}
              {/* Only for a card with a real cap -- see Unit.abilityMaxUses'
                  own comment on why null means unlimited (every card that
                  predates 0056, and any Active sentence authored with
                  "Infinite" uses). Cooldown, once it is running, is shown
                  regardless of uses-left -- either one alone is reason
                  enough for the button to read as "not right now". */}
              {selected.abilityKind === 'scripted' && selected.abilityMaxUses != null && (
                <span className="actmenu-abilitycost">{abilityUsesLeft}/{selected.abilityMaxUses}</span>
              )}
              {selected.abilityKind === 'scripted' && abilityOnCooldown && (
                <span className="actmenu-abilitycost">⏳{abilityCooldownLeft}</span>
              )}
            </button>
            <button
              role="menuitem"
              aria-disabled={Boolean(defendDisabledReason)}
              title={defendDisabledReason ?? t('board.defendNote')}
              onClick={() => {
                if (defendDisabledReason) {
                  setExplain({ title: t('board.defend'), body: defendDisabledReason })
                  return
                }
                onDefend(selected.id)
                setMode(null)
              }}
            >
              <span className="actmenu-icon actmenu-icon-defend">
                <img src={artUrl('fx/guard.webp')!} alt="" aria-hidden="true" />
              </span>
              {t('board.defend')}
            </button>
            {/* Wait removed entirely (2026-09) -- Jared: "if they don't want
                to do anything, they can end their turn as usual, no need for
                this option". It was never load-bearing: cn_begin_act already
                closes out whatever unit was mid-go the moment a DIFFERENT
                unit begins its own act, and advance_turn resets `active` and
                every unit's `spent` flag outright when the turn ends either
                way -- so "select something else" or "End Turn" already did
                everything submit_wait did. See 0086's migration comment for
                the server-side half of this removal. */}
            <button
              role="menuitem"
              className="actmenu-cancel"
              onClick={() => { onSelect(null); setMode(null) }}
            >
              <span className="actmenu-icon actmenu-icon-cancel"><IconClose /></span>
              {t('board.cancel')}
            </button>
          </div>
        </div>
      )}

      {/* The cinematic. Scheduled from here because this is where the board a
          moment ago lives, but PORTALED to document.body rather than rendered
          as an ordinary child -- `.duel` is `position: fixed; inset: 0`,
          meant to cover the true viewport edge to edge, and .board picked up
          its own `perspective` (for the move-tilt's real 3D) which, per the
          CSS spec, makes .board a CONTAINING BLOCK for any fixed-position
          descendant, the exact same way a `transform` would. Left as an
          ordinary child, the cinematic was sizing and centering itself
          against .board's own small, centered box instead of the window --
          Jared: "if the combat scene ever dares to show up, now it's in the
          fricking middle of the screen, super weird." A portal is the
          standing fix already used for exactly this shape of problem
          (Ability.tsx's own hover bubble, same reasoning, same target) rather
          than something narrower like stripping .board's perspective (which
          the tilt still needs) or re-deriving a viewport-relative position by
          hand. */}
      {cine && createPortal(
        <Duel
          // Keyed by the exchange, so the next one in the queue is a FRESH
          // component rather than the same one handed different props. Without
          // it the scheduling effect would have to unwind a half-played
          // timeline, and `done` would still be latched from the last fight.
          key={cine.seq}
          cine={cine}
          mySide={mySide}
          onDone={endCine}
        />,
        document.body,
      )}

      {/* Everything below is transient: it exists only while an exchange plays. */}
      {/* An ability's numbers, one per unit it reached. */}
      {pops.map((h) => {
        const u = state.units.find((x) => x.id === h.id)
        if (!u) return null
        return h.heal !== undefined && h.heal > 0
          ? (
            <Fragment key={h.id}>
              <div className="dmg dmg-heal" style={at({ x: u.x, y: u.y })}>+{h.heal}</div>
              <HealBurst key={`hb-${h.id}`} style={at({ x: u.x, y: u.y })} />
            </Fragment>
          )
          : <div key={h.id} className="dmg" style={at({ x: u.x, y: u.y })}>-{h.dmg}</div>
      })}

      {/* Deaths `blow` above never heard about -- see deathGhosts' own
          comment by its useState. Same ghost-card vanish `blow.killedTgt`
          plays, at the dead unit's LAST known tile (`g.unit` is the snapshot
          from before it vanished, not a live lookup -- there is no live
          unit to look up any more). No lunge/recoil synthesised for it: an
          effect or a status killed this unit, not another unit striking it,
          so there is no attacker here to react. */}
      {deathGhosts.map((g) => (
        <div key={`${g.id}:${g.seq}`} className="unit-ghost" style={at({ x: g.unit.x, y: g.unit.y })}>
          <GhostCard unit={g.unit} />
        </div>
      ))}

      {blow && (
        <>
          {blow.killedTgt && blow.tgtUnit && (
            <div className="unit-ghost" style={at(blow.tgtAt)}>
              <GhostCard unit={blow.tgtUnit} />
            </div>
          )}
          {blow.killedAtk && (
            <div className="unit-ghost unit-ghost-late" style={at(blow.atkAt)}>
              <GhostCard unit={blow.atkUnit} />
            </div>
          )}
          {blow.heal > 0
            ? (
              <>
                <div className="dmg dmg-heal" style={at(blow.tgtAt)}>+{blow.heal}</div>
                <HealBurst key={`hb-${blow.seq}`} style={at(blow.tgtAt)} />
              </>
            )
            : <div className="dmg" style={at(blow.tgtAt)}>-{blow.dmg}</div>}
          {blow.counter > 0 && (
            <div className="dmg dmg-late" style={at(blow.atkAt)}>-{blow.counter}</div>
          )}
          {blow.burnTgt > 0 && (
            <div className="dmg dmg-burn dmg-late" style={at(blow.tgtAt)}>-{blow.burnTgt}</div>
          )}
          {blow.burnAtk > 0 && (
            <div className="dmg dmg-burn dmg-late" style={at(blow.atkAt)}>-{blow.burnAtk}</div>
          )}
        </>
      )}
    </div>

    {/* FRIENDLY FIRE CONFIRMATION -- see clickUnit's own comment. Outside
        the .board div (a Fragment sibling, not a child) so it sits above
        the whole board regardless of the grid's own stacking, the same as
        every other Modal in this app. */}
    {confirmAttackId && (
      <Modal title={t('board.friendlyFireConfirm')} onClose={() => setConfirmAttackId(null)}>
        <div className="actionbar">
          <button className="btn ghost" onClick={() => setConfirmAttackId(null)}>
            {t('common.cancel')}
          </button>
          <button
            className="btn danger"
            onClick={() => {
              onAttack(confirmAttackId)
              setConfirmAttackId(null)
              setMode(null)
            }}
          >
            {t('board.friendlyFireYes')}
          </button>
        </div>
      </Modal>
    )}

    {/* WHY NOT. Clicking/tapping a greyed-out action menu button lands here
        instead of on whatever it would otherwise have done -- see the
        aria-disabled buttons above and moveDisabledReason/attackDisabledReason/
        abilityDisabledReason/defendDisabledReason for the actual wording. */}
    {explain && (
      <Modal title={explain.title} onClose={() => setExplain(null)}>
        <p>{explain.body}</p>
      </Modal>
    )}
    </>
  )
}

/**
 * The angle, in degrees, from one DRAWN tile to an adjacent one -- 0 is
 * "up", turning clockwise the way a compass does on screen. Both cardinal
 * and diagonal neighbours are just a value on the same continuous scale (0,
 * 45, 90, ... 315) rather than a `north`/`south`/`east`/`west` label picked
 * by looking at one axis at a time, which is what let the old side() drop
 * the other axis on the floor for every diagonal step. Only ever called on
 * two tiles one step apart, cardinal or diagonal, so the result is always
 * one of those eight values.
 */
function angleTo(from: { x: number; y: number }, to: { x: number; y: number }): number {
  return (Math.atan2(to.x - from.x, from.y - to.y) * 180) / Math.PI
}

/**
 * One tile's worth of route, in its own grid cell: a triangle pointing the
 * way the unit would travel through this tile, in that unit's own class
 * colour (--role-rgb -- see .unit.role-* in styles.css for the same five
 * values; a role with no match there falls back to the old arrow's blue).
 *
 * Replaces ArrowPart (see the map above this component's call site for why):
 * one shape, rotated, instead of a set of edge-to-edge line segments that
 * only ever knew about four directions. It floats gently in place
 * (movearrow-float, in styles.css) rather than sitting dead still -- purely
 * decorative, so `prefers-reduced-motion` and the in-app reduced-motion
 * setting both turn it off the same way every other idle animation here does.
 */
function MoveTriangle({ style, angle, role, delayMs, ghost = false }: {
  style: React.CSSProperties
  angle: number
  role: string
  delayMs: number
  /** Their arrow, not yours -- see .movearrow.is-ghost in styles.css. */
  ghost?: boolean
}) {
  // The float used to be a blind translateY, however the triangle itself was
  // rotated -- an arrow pointing left or right still just bobbed up and down.
  // Jared: "the back-and-forth wave-like animation... should happen according
  // to the direction they're pointing to." `angle` is already the same
  // 0-is-up, clockwise-on-screen value the rotate() above uses, so the
  // wiggle's own axis is just that angle turned into a unit vector on the
  // same two screen axes CSS transforms move along -- sin for x, -cos for y
  // (0deg/up -> (0,-1), 90deg/right -> (1,0), and so on around the compass).
  // A diagonal angle (45, 135, ...) lands on (+-0.707, +-0.707) for free,
  // the same way every cardinal one lands on an axis for free -- one formula,
  // not a north/south/east/west/diagonal case list to keep in sync with
  // angleTo() above.
  const rad = (angle * Math.PI) / 180
  const wigDx = Math.sin(rad)
  const wigDy = -Math.cos(rad)
  return (
    <div
      className="movearrow-cell"
      style={{
        ...style,
        animationDelay: `${delayMs}ms`,
        '--wig-dx': wigDx.toFixed(3),
        '--wig-dy': wigDy.toFixed(3),
      } as React.CSSProperties}
    >
      <svg
        className={`movearrow${role ? ` role-${role}` : ''}${ghost ? ' is-ghost' : ''}`}
        style={{ transform: `rotate(${angle}deg)` }}
        viewBox="0 0 100 100" aria-hidden="true"
      >
        <polygon points="50,12 84,80 16,80" />
      </svg>
    </div>
  )
}

/**
 * Something standing on a tile that is not a unit.
 *
 * A tree is a crop of the painting, because a tile of woodland reads as cover
 * at a glance and an icon reads as a piece. The three summons are drawn here
 * in SVG rather than being three more image files: they are shapes, not
 * scenery, and a summoned thing that looked like terrain would be read as
 * terrain. Each carries its owner's colour, because whose wall it is decides
 * whether it is in your way or in theirs.
 */
function Thing({
  thing, style, targetable, shaking, falling, landing, landingDelayMs, prereveal, mine,
  onClick, onHover, onPeek,
}: {
  thing: Obstacle
  style: React.CSSProperties
  targetable: boolean
  shaking: boolean
  falling: boolean
  /** Just arrived this exchange, OR (since the tile-by-tile board build) one
   *  of the trees standing here when the match started -- either way, plays
   *  the tilt-and-place entrance instead of appearing flat. See
   *  .tree.is-landing in styles.css and LANDING_MS above, which drives it. */
  landing: boolean
  /** This tree's own stagger within whichever wave is landing it, in ms --
   *  0 for a mid-match arrival (they land together), the board-build
   *  sweep's own per-tree delay for one of the initial trees. See
   *  revealTiles() above and --reveal-delay in styles.css. */
  landingDelayMs?: number
  /** True for one of the board's initial trees before wave zero has reached
   *  it -- a plain, invisible hold, the exact same job
   *  `.unit-slot.is-prereveal` does for a not-yet-landed unit (see that
   *  prop's own comment): unconditional from this tree's very first
   *  render, not merely once `landing` happens to flip true. */
  prereveal: boolean
  /** Whether this is the viewer's own summon. Null for a tree, which is
   *  nobody's. */
  mine: boolean | null
  onClick: (e: React.MouseEvent) => void
  onHover: (over: boolean) => void
  onPeek: () => void
}) {
  const t = useT()
  const kind = objKind(thing)
  const pct = Math.max(0, Math.min(100, (thing.hp / thing.maxHp) * 100))
  const press = useLongPress(onPeek)
  return (
    <div className="tree-slot" style={style}>
      <div
        className={['tree', `thing-${kind}`,
                    mine === true ? 'is-ours' : mine === false ? 'is-theirs' : '',
                    targetable ? 'is-target' : '', shaking ? 'is-hit' : '',
                    falling ? 'is-falling' : '',
                    landing ? 'is-landing' : '', prereveal ? 'is-prereveal' : ''].join(' ')}
        style={landing
          ? ({ '--landing-ms': `${LANDING_MS}ms`, '--reveal-delay': `${landingDelayMs ?? 0}ms` } as React.CSSProperties)
          : undefined}
        title={t(objNameKey(kind)) || kind}
        {...press.handlers}
        onClick={(e) => { if (press.swallowed()) { e.stopPropagation(); return } onClick(e) }}
        onMouseEnter={() => onHover(true)}
        onMouseLeave={() => onHover(false)}
      >
        {kind === 'tree'
          ? <img src={`${import.meta.env.BASE_URL}tree.webp`} alt="" />
          : <ThingGlyph kind={kind} />}
        {/* An untouched thing shows no bar. Its health is a fact you read off
            the card, not something the board has to shout at you six times. */}
        {pct < 100 && (
          <div className="tree-hp">
            <span style={{ width: `${pct}%` }} />
            <b>{thing.hp}</b>
          </div>
        )}
      </div>
    </div>
  )
}

/** The three summons, as shapes. currentColor throughout, so the owner's
 *  colour is set once on the wrapper in CSS and nothing here repeats it.
 *  Exported (0079) so BigCard.tsx's hover card can draw the same icon the
 *  board itself does for anything without an uploaded `art_url`, instead
 *  of always showing tree.webp. */
export function ThingGlyph({ kind }: { kind: ObjKind }) {
  if (kind === 'wall') {
    // Courses of stone. Staggered joints, because a wall drawn as a grid of
    // squares reads as a window.
    return (
      <svg className="thing-glyph" viewBox="0 0 24 24" aria-hidden="true">
        <rect x="2" y="4" width="20" height="16" rx="1.5"
              fill="currentColor" fillOpacity="0.22" />
        <g stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" fill="none">
          <path d="M2 9.3h20M2 14.7h20" />
          <path d="M9 4v5.3M16 4v5.3M5.5 9.3v5.4M12.5 9.3v5.4M19 9.3v5.4M9 14.7V20M16 14.7V20" />
          <rect x="2" y="4" width="20" height="16" rx="1.5" />
        </g>
      </svg>
    )
  }
  if (kind !== 'wall' && kind !== 'bomb' && kind !== 'tornado') {
    // Since 0057: any structures-catalog slug that is not one of the three
    // hand-drawn shapes below -- a generic mark rather than the tornado
    // funnel this fell through to (silently, wrongly) before this branch
    // existed. A per-structure picture is `structures.art_url`, not read
    // here -- see objSolid's own comment on the client-catalog follow-up
    // this migration leaves for later.
    return (
      <svg className="thing-glyph" viewBox="0 0 24 24" aria-hidden="true">
        <rect x="5" y="5" width="14" height="14" rx="3"
              fill="currentColor" fillOpacity="0.22" stroke="currentColor" strokeWidth="1.6" />
        <circle cx="12" cy="12" r="2.6" fill="currentColor" />
      </svg>
    )
  }
  if (kind === 'bomb') {
    // A sea mine: heavy body, SHORT stubby horns, one highlight. The horns
    // were the length of the tile in the first draft and the whole thing read
    // as a sun -- measured against the other two on one page, which is the
    // only way to tell.
    return (
      <svg className="thing-glyph" viewBox="0 0 24 24" aria-hidden="true">
        <g stroke="currentColor" strokeWidth="2" strokeLinecap="round">
          <path d="M12 3.4v2.6M12 18v2.6M3.4 12h2.6M18 12h2.6
                   M5.9 5.9l1.9 1.9M16.2 16.2l1.9 1.9M18.1 5.9l-1.9 1.9M7.8 16.2l-1.9 1.9" />
        </g>
        <circle cx="12" cy="12" r="6.2" fill="currentColor" />
        <circle cx="9.8" cy="9.8" r="1.5" fill="var(--paper)" fillOpacity="0.75" />
      </svg>
    )
  }
  // A funnel: wide mouth, narrow foot, and curved, because straight lines
  // stacked shortest-last read as a signal-strength meter rather than as
  // weather. Two outline curves and two of wind inside them.
  return (
    <svg className="thing-glyph" viewBox="0 0 24 24" aria-hidden="true">
      <g stroke="currentColor" strokeWidth="1.9" strokeLinecap="round"
         strokeLinejoin="round" fill="none">
        <path d="M3.6 5.2C8 8 16 8 20.4 5.2" />
        <path d="M3.6 5.2C5.4 11.4 8.8 16.6 11 21" />
        <path d="M20.4 5.2C18.6 11.4 15.2 16.6 13 21" />
      </g>
      <g stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"
         fill="none" opacity="0.6">
        <path d="M6.6 10.2C9.2 11.6 14.4 11.6 17.2 10.2" />
        <path d="M9 15.4C10.6 16.2 13 16.2 14.6 15.4" />
      </g>
    </svg>
  )
}

/** The zoomed crop, falling back to the whole illustration if the crop is
 *  not there. onError fires once and then the src is the full picture, so
 *  this cannot loop. */
function Portrait({ unit }: { unit: Unit }) {
  return (
    <img
      src={faceUrl(unit.art)!}
      alt=""
      onError={(e) => {
        const el = e.currentTarget
        const full = artUrl(unit.art)
        if (full && el.src !== full) el.src = full
      }}
    />
  )
}

function GhostCard({ unit }: { unit: Unit }) {
  return (
    <div className={`unit unit-ghost-card ${unit.owner === 'host' ? 'unit-host' : 'unit-guest'}`}
         style={{ '--accent': unit.accent } as React.CSSProperties}>
      <div className="unit-face">
        <div className="unit-art">
          {unit.art ? <Portrait unit={unit} /> : <span className="unit-initial">{unit.name[0]}</span>}
        </div>
      </div>
    </div>
  )
}

function UnitCard({
  unit, slot, yours, watching, selected, target, counters, caught, swamped, mendable,
  burst, statusBursts, slotClass, slotVars, onClick, onHover, onPeek, slotRef,
}: {
  unit: Unit
  slot: React.CSSProperties
  yours: boolean
  watching: boolean
  selected: boolean
  target: 'foe' | 'ally' | 'tree' | null
  counters: boolean
  /** The gale has hold of this one and everybody is waiting on a decision
   *  about it. See the `pending` block up in Board. */
  caught: boolean
  /** The selected unit would MEND this one rather than strike it. Only
   *  meaningful when `target` is 'ally'. */
  mendable: boolean
  /** Non-zero when a blow has just landed on this unit, and CHANGING on every
   *  new one -- it is the exchange's sequence number, so React remounts the
   *  burst and the animation restarts rather than being ignored as an
   *  unchanged subtree. */
  burst: number
  /** Afflictions that landed on this unit THIS exchange -- see StatusBurst.tsx.
   *  `seq` is fx.seq, keyed into the element below the same remount-by-key
   *  reason `burst` above already uses. */
  statusBursts: { kind: Affliction; seq: number }[]
  /** Standing next to somebody's Umiro. Positional, so it is computed by the
   *  board and handed down rather than read off the unit. */
  swamped: boolean
  slotClass: string
  slotVars?: React.CSSProperties
  onClick: (e: React.MouseEvent) => void
  onHover: (over: boolean) => void
  onPeek: () => void
  slotRef: (el: HTMLDivElement | null) => void
}) {
  const press = useLongPress(onPeek)
  const hpPct = Math.max(0, Math.min(100, (unit.hp / unit.maxHp) * 100))
  // Jared, this round: back on the token after all -- see the icon row
  // rendered below and its own comment for the history. Same list BigCard's
  // bc-effects panel builds off of (afflictionsOf + swamp, guard from
  // unit.defending since it isn't a field afflictionsOf reads), same order
  // the old always-on row drew them in.
  const marks: Mark[] = [
    ...(unit.defending ? ['guard' as const] : []),
    ...afflictionsOf(unit),
    ...(swamped ? ['swamp' as const] : []),
  ]

  // The piece on the board no longer leans toward the pointer -- it holds
  // still and only lifts, because a token that tips while you are trying to
  // read the art is the art losing. The movement moved to the big card
  // opening beside the board, which still takes its angles from here: the
  // arena's --brx/--bry. Written straight to the DOM rather than held in
  // state, because this fires on every mouse move and re-rendering the board
  // sixty times a second to tilt one card is not a trade worth making.
  function lean(e: React.MouseEvent<HTMLDivElement>) {
    const r = e.currentTarget.getBoundingClientRect()
    const px = (e.clientX - r.left) / r.width - 0.5
    const py = (e.clientY - r.top) / r.height - 0.5
    const arena = e.currentTarget.closest('.arena') as HTMLElement | null
    arena?.style.setProperty('--bry', `${(px * MAX_TILT * 2).toFixed(1)}deg`)
    arena?.style.setProperty('--brx', `${(-py * MAX_TILT * 2).toFixed(1)}deg`)
  }
  function settle(e: React.MouseEvent<HTMLDivElement>) {
    const arena = e.currentTarget.closest('.arena') as HTMLElement | null
    arena?.style.setProperty('--bry', '0deg')
    arena?.style.setProperty('--brx', '0deg')
  }

  const portrait = unit.art
    ? <Portrait unit={unit} />
    : <span className="unit-initial">{unit.name[0]}</span>

  return (
    <div ref={slotRef} className={`unit-slot ${slotClass}`.trim()} style={{ ...slot, ...slotVars }}>
      <div
        className={[
          'unit',
          // Colour is the SIDE, never "mine" -- otherwise the guest sees their
          // own units in the host's colour, and a spectator sees both armies
          // as the enemy.
          unit.owner === 'host' ? 'unit-host' : 'unit-guest',
          unit.role ? `role-${unit.role}` : '',
          yours ? 'is-yours' : '',
          watching ? 'is-inert' : '',
          selected ? 'is-selected' : '',
          target ? `is-target is-target-${target}` : '',
          isBurning(unit) ? 'is-burned' : '',
          isPoisoned(unit) ? 'is-poisoned' : '',
          isStunned(unit) ? 'is-stunned' : '',
          swamped ? 'is-swamped' : '',
          caught ? 'is-caught' : '',
          unit.defending ? 'is-guarding' : '',
          // `spent` is the server's word for "this one has had its go", and it
          // is the honest one now: a unit that moved and chose not to strike
          // is finished for the turn without ever having acted. The old test
          // is kept behind it for a match that was already running when 0019
          // landed and whose units carry no `spent` at all.
          (unit.spent ?? (unit.moved && unit.acted)) ? 'is-spent' : '',
        ].join(' ')}
        style={{ '--accent': unit.accent } as React.CSSProperties}
        onMouseMove={lean}
        onMouseEnter={() => onHover(true)}
        onMouseLeave={(e) => { settle(e); onHover(false) }}
        {...press.handlers}
        onClick={(e) => { if (press.swallowed()) { e.stopPropagation(); return } onClick(e) }}
      >
        {/* On the board a card is its picture and nothing else. The name and
            the numbers are one hover away; what you need at a glance is who it
            is and how much of it is left. */}
        <div className="unit-face">
          <div className="unit-art">{portrait}</div>
          <div className="unit-hpbar">
            <span className="unit-hpfill" style={{ width: `${hpPct}%` }} />
            <b className="unit-hpnum">{unit.hp}</b>
          </div>
        </div>

        {/* Jared, this round: wants it back -- "units should have the icon
            of the status they currently have... on top of their tokens".
            This doesn't replace bc-effects (BigCard.tsx's hover/click/
            long-press panel, which still carries the description sentence
            each mark gets) -- it is the same set of icons, MARK_ART, drawn
            small and silent across the token itself so the news doesn't
            need a hover to see at all. The ambient glow this row used to be
            "instead of" (is-burned/-poisoned/-stunned/-swamped above) stays
            too, its pulse widened from a subtle 8-24% to 20-60% opacity per
            the same request, and now covers is-swamped as well -- see
            styles.css's fx-status-pulse. There's no tracked "stat lowered"
            affliction in this game today (nothing sets one, nothing reads
            one -- see lib/effects.ts's own Affliction/Mark union), so there
            is nothing yet for a fifth icon to mean; add one to that union
            and MARK_ART the day a card actually lowers a stat. */}
        {marks.length > 0 && (
          <div className="unit-marks">
            {marks.map((m) => (
              <img
                key={m} className={`unit-mark-icon unit-mark-${m}`}
                src={artUrl(MARK_ART[m])!} alt="" aria-hidden="true"
              />
            ))}
          </div>
        )}
        {/* An ally is a MEND when the selected unit heals and a BLOW when it
            does not, and since 0038 it may be either -- so the crosshair asks
            which rather than assuming. Green for a mend, and for a blow at
            your own the same dashed danger ring an enemy gets, because it is
            the same blow. Nothing on the roster heals today, so in practice
            an ally is always the second one. */}
        {burst > 0 && <HitBurst key={burst} />}
        {statusBursts.map(({ kind, seq }) => (
          <StatusBurst key={`${kind}-${seq}`} kind={kind} />
        ))}
        {target === 'ally' && (
          <div className={`unit-crosshair${mendable ? ' is-mend' : ' is-friendly'}`} />
        )}
        {target === 'foe' && <div className={`unit-crosshair${counters ? ' is-risky' : ''}`} />}
      </div>
    </div>
  )
}
