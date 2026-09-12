import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { MatchState, Obstacle, Side, Unit } from '../lib/types'
import type { Ghost } from '../lib/useGhost'
import { getSettings } from '../lib/settings'
import { buildCine, fighterOf, fighterOfTree, quicken, type Cine } from '../lib/cine'
import { useT } from '../lib/i18n'
import { Duel } from './Duel'
import { artUrl, faceUrl } from '../lib/art'
import {
  canAct, cheb, deployTiles, draw, drawSign, flipFor, key, losClear, occupied,
  ownSide, pathTo, reachable,
  targetsFor, undraw, willCounter, type Target,
} from '../lib/rules'
import { playMove, playPlace, playSelect } from '../lib/sfx'
import {
  MARK_ART, afflictionsOf, isBurning, isPoisoned, isStunned,
  type Affliction,
} from '../lib/effects'
import { THROW_REACH, objKind, objNameKey, objSolid, type ObjKind } from '../lib/objects'

// No pixel sizes here on purpose. The board is a CSS grid that fills whatever
// space it is given and keeps its aspect ratio.
const MAX_TILT = 16   // degrees the card leans toward the cursor

/** How long a finger has to stay put before a card opens under it. Long
 *  enough not to fire on a tap, short enough that nobody thinks it is
 *  broken -- the same range a phone uses for its own press-and-hold. */
const LONG_MS = 420
/** And how far it may drift first. Past this it is a scroll or a drag, not a
 *  press, and a card that opens while somebody is dragging the board is a
 *  card in the way. */
const LONG_SLOP = 10

/**
 * Press and hold to read a card.
 *
 * A phone has no pointer, so the card that opens beside the board on a desktop
 * has nothing to open for. The strip under the board covers the unit you have
 * SELECTED, but selecting is also how you move -- so there was no way at all
 * to read a card belonging to the other side, or a tree, without committing to
 * something.
 *
 * Touch only, on purpose. A mouse already has hover, and a right-hand-side
 * card that also appeared after holding the left button down would fire every
 * time somebody started a drag.
 *
 * The tap that ends a long press must NOT also select, so the fired flag is
 * copied into `swallow` on the way up and read by the click handler that comes
 * after it -- pointerup has already reset everything else by then.
 *
 * Lifting does NOT close the card. It used to, which meant a card could only
 * be read with a finger held over the board -- and made the purple keywords on
 * it impossible to tap at all, since tapping means letting go first.
 */
function useLongPress(onFire: () => void) {
  const timer = useRef<number | undefined>(undefined)
  const from = useRef<{ x: number; y: number } | null>(null)
  const fired = useRef(false)
  const swallow = useRef(false)

  const stop = () => {
    window.clearTimeout(timer.current)
    from.current = null
    if (fired.current) { fired.current = false; swallow.current = true }
  }
  useEffect(() => () => window.clearTimeout(timer.current), [])

  return {
    handlers: {
      onPointerDown(e: React.PointerEvent) {
        // Disarm first. `swallow` is set on the way up and meant to be eaten
        // by the click that follows -- but since a peeked card puts a scrim in
        // the way, that click can land somewhere else entirely and never
        // arrive. Left armed it ate the NEXT ordinary tap on this unit, so a
        // long press made the unit unselectable exactly once, which is the
        // kind of bug nobody reports and everybody feels.
        swallow.current = false
        if (e.pointerType !== 'touch') return
        from.current = { x: e.clientX, y: e.clientY }
        fired.current = false
        window.clearTimeout(timer.current)
        timer.current = window.setTimeout(() => { fired.current = true; onFire() }, LONG_MS)
      },
      onPointerMove(e: React.PointerEvent) {
        const a = from.current
        if (!a) return
        if (Math.hypot(e.clientX - a.x, e.clientY - a.y) > LONG_SLOP) stop()
      },
      onPointerUp: stop,
      onPointerCancel: stop,
      onContextMenu(e: React.MouseEvent) { if (swallow.current) e.preventDefault() },
    },
    /**
     * True once, for the click that follows the press that opened a card.
     *
     * A caller that gets `true` must ALSO stop the event. Ignoring it is not
     * enough: the board's own background handler clears the selection, so a
     * click the unit declines to act on but lets past is a long press that
     * puts the unit down -- which is exactly what "reading a card must change
     * nothing" is not.
     */
    swallowed() {
      if (!swallow.current) return false
      swallow.current = false
      return true
    },
  }
}
const FX_MS = 1300

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
  /** Close the open go without striking. Takes no unit: the server already
   *  knows which one is mid-go, and asking it is how the two stay agreed. */
  onWait: () => void
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

export function Board({
  state, mySide, isMyTurn, deploying, selectedId, onSelect, onMove, onAttack, onAbility, onThrow, onDefend,
  onWait, onDeploy, onHover, onPeek, ghost = null, onLook, onWatching,
}: Props) {
  const t = useT()
  const { w, h } = state.board
  const trees: Obstacle[] = state.obstacles ?? []
  const selected = state.units.find((u) => u.id === selectedId) ?? null

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
    }

    if (moves.length <= 2) {
      for (const m of moves) {
        m.el.animate(
          [{ transform: `translate(${m.dx}px, ${m.dy}px)` }, { transform: 'translate(0px, 0px)' }],
          { duration: 240, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' },
        )
      }
      // One sound for the whole change, not one per card: a deployment swap
      // is two cards but a single act. Sounding it here rather than in the
      // click handler means the opponent's move is audible too, and means a
      // move the server refused stays silent.
      if (moves.length) (deploying ? playPlace : playMove)()
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
  useEffect(() => { onWatching?.(queue.length > 0) }, [queue.length, onWatching])

  useEffect(() => {
    const fx = state.fx
    const prev = before.current
    before.current = { units: state.units, trees }
    if (!fx || fx.seq === lastSeq.current) return
    lastSeq.current = fx.seq

    const a = prev.units.find((u) => u.id === fx.atk)

    // ---- an ability -------------------------------------------------------
    // No cinematic: the Duel is two fighters facing each other and an ability
    // is one unit and a crowd. What it gets instead is the board's own
    // language -- a number off every unit it touched -- which is the half that
    // is information rather than performance.
    if (fx.kind === 'ability') {
      setPops(fx.hits ?? [])
      const done = setTimeout(() => setPops([]), FX_MS)
      return () => clearTimeout(done)
    }

    // Past the ability branch, an fx always names a target -- only an ability
    // may have none. Said as a guard rather than asserted with `!`, because
    // the day a third kind of fx arrives this is where it should stop.
    if (fx.tgt == null) return
    const tgt = prev.units.find((u) => u.id === fx.tgt)
    const wood = prev.trees.find((o) => o.id === fx.tgt)
    if (!a || (!tgt && !wood)) return

    // `t` is the translator here; the target unit is `tgt`. They were both
    // called t once and that is exactly the kind of collision worth renaming
    // out of existence rather than working around.
    // 'off' means no TAKEOVER, not no feedback: the lunge, the shake and the
    // damage numbers below are the board's own and they stay. What goes is the
    // full-screen retelling, which is the part that is a performance rather
    // than information.
    const mode = getSettings().cine
    if (mode !== 'off') {
      const next = buildCine(fx, fighterOf(a), tgt ? fighterOf(tgt) : fighterOfTree(wood!), t)
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
    const id = setTimeout(() => setBlow(null), FX_MS)
    return () => clearTimeout(id)
  }, [state])

  const mine = selected && selected.owner === mySide

  const [mode, setMode] = useState<Mode | null>(null)
  // The menu belongs to the selection, so it dies with it -- including when
  // Match drops the selection because the turn flipped under us.
  useEffect(() => { if (!selectedId) setMode(null) }, [selectedId])

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

  // WHAT AN ABILITY CAN BE POINTED AT. Three of the five take a target, and
  // no two of them take the same set, which is why this is a switch and not
  // the attack's target list with a different name:
  //   heal_any   any unit in reach, ally or enemy, line of sight required
  //   poison_hit enemies only, line of sight required
  //   line_burn  any unit in reach -- a fireball arcs, so no line of sight
  // Lit here so the board can show it; the server decides, as always, and
  // every one of these rules is asserted on that side too.
  const aims = useMemo(() => {
    const out = new Map<string, Target>()
    if (!selected || !mine || deploying || !canStrike) return out
    const kind = selected.abilityKind
    if (kind !== 'heal_any' && kind !== 'poison_hit' && kind !== 'line_burn') return out
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
  }, [state, selected, mine, deploying, canStrike])

  // WHERE A SUMMONER MAY PUT SOMETHING. A tile rather than a unit, which is
  // the one thing the ability menu has never had to point at before -- Mako's
  // trap, Fey's wall and Lumea's tornado all land on empty ground. Mirrors the
  // summon branch of cn_ability: in reach, line of sight clear, nothing
  // standing there and nothing already lying there.
  const summonTiles = useMemo(() => {
    const out = new Set<string>()
    if (!selected || !mine || deploying || !canStrike) return out
    if (selected.abilityKind !== 'summon') return out
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

  /** Does this unit's ability need something clicked before it fires? */
  const aimed = selected?.abilityKind === 'heal_any'
    || selected?.abilityKind === 'poison_hit'
    || selected?.abilityKind === 'line_burn'
    || selected?.abilityKind === 'summon'

  /** Can this unit use its ability at all, right now? */
  const canAbility = Boolean(
    selected && mine && isMyTurn && selected.abilityKind && !selected.acted
    && canAct(state, selected) && !isStunned(selected)
    && (!aimed || aims.size > 0 || summonTiles.size > 0),
  )

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
    if (k !== 'aoe_adjacent' && k !== 'mist') { setMode(null); return }
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
    : showAims ? summonTiles : new Set<string>()
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
    if (watching(mySide)) return
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
      setMode(null)
      return
    }
    if (shownTiles.has(key(x, y))) { onMove(x, y); setMode('menu') }
    else { onSelect(null); setMode(null) }
  }

  function clickUnit(u: Unit) {
    if (watching(mySide)) return
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
      if (showAims) onAbility(selectedId!, u.id); else onAttack(u.id)
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
        return (
          <div
            key={k}
            // Explicit placement, not auto-flow: everything else on this grid
            // is placed by coordinate, and CSS grid positions definite items
            // first, so auto-flowed tiles would be pushed off the end.
            style={at({ x, y })}
            className={[
              'tile',
              ownSide(halfSide, y, h) ? 'tile-mine' : 'tile-theirs',
              lit ? (deploying ? 'tile-deploy'
                    : (showAims || throwing) ? 'tile-aim' : 'tile-move') : '',
              theirs.tiles.has(k) ? 'tile-theirlook' : '',
            ].join(' ')}
            onClick={(e) => { e.stopPropagation(); clickTile(x, y) }}
          />
        )
      })}

      {/* Where your ground stops. The tint on the tiles says it quietly; this
          says it at a glance, which is what you want while deploying. It sits
          on the far edge of row h/2 whichever way up the board is drawn --
          the flip moves which rows that row is between, not where the seam is
          on the screen, because the seam is always across the middle. */}
      <div
        className="halfline"
        aria-hidden="true"
        style={{ gridColumn: '1 / -1', gridRow: Math.floor(h / 2) + 1 }}
      />

      {trees.map((t) => (
        <Thing
          key={t.id}
          thing={t}
          style={at(t)}
          mine={t.owner == null ? null : t.owner === mySide}
          targetable={shownTargets.has(t.id)}
          shaking={blow?.tgt === t.id}
          falling={blow?.tgt === t.id && blow.killedTgt}
          onHover={(over) => onHover(over ? t.id : null)}
          onPeek={() => onPeek?.(t.id)}
          onClick={(e) => {
            e.stopPropagation()
            if (shownTargets.has(t.id)) {
              if (showAims) onAbility(selectedId!, t.id); else onAttack(t.id)
              setMode(null)
            }
            else { onSelect(null); setMode(null) }
          }}
        />
      ))}

      {state.units.map((u) => {
        const striking = blow?.atk === u.id
        const struck = blow?.tgt === u.id
        const target = shownTargets.get(u.id)
        return (
          <UnitCard
            key={u.id}
            unit={u}
            slot={at(u)}
            yours={mySide !== null && u.owner === mySide}
            watching={watching(mySide)}
            selected={u.id === selectedId}
            target={target ? target.kind : null}
            counters={target ? willCounter(selected!, target) : false}
            caught={pending?.unit === u.id}
            slotClass={[
              striking ? 'fx-strike' : '',
              struck && !blow?.killedTgt && !blow?.heal ? 'fx-hurt' : '',
              struck && blow!.heal > 0 ? 'fx-mend' : '',
              struck && blow!.counter > 0 ? 'fx-strike-late' : '',
              striking && blow!.counter > 0 && !blow!.killedAtk ? 'fx-hurt-late' : '',
            ].join(' ')}
            slotVars={
              striking && blow
                ? lungeVars(blow.atkAt, blow.tgtAt)
                : struck && blow
                  ? lungeVars(blow.tgtAt, blow.atkAt)
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

      {/* The movement arrow. Drawn the way Fire Emblem draws it: one piece of
          arrow per tile of the route rather than one line across the board.
          Every piece is an ordinary grid item in its own cell, so it needs no
          pixel arithmetic and cannot drift when the board is resized -- the
          bug that this project has been bitten by twice.
          Purely a picture of what clicking would do; the click itself is the
          tile's, underneath. */}
      {arrow && arrow.length > 1 && arrow.map((p, i) => (
        <ArrowPart
          key={`${p.x},${p.y}`}
          style={at(p)}
          from={i > 0 ? side(draw(arrow[i - 1], w, h, flip), draw(p, w, h, flip)) : null}
          to={i < arrow.length - 1 ? side(draw(arrow[i + 1], w, h, flip), draw(p, w, h, flip)) : null}
        />
      ))}

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
            <button
              role="menuitem"
              disabled={!canMove || litTiles.size === 0}
              onClick={() => setMode('move')}
            >
              {t('board.move')}
            </button>
            <button
              role="menuitem"
              disabled={!canStrike || targets.size === 0}
              onClick={() => setMode('attack')}
            >
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
              disabled={!canAbility}
              title={selected.abilityKind ? undefined : t('board.abilityPassive')}
              onClick={fireAbility}
            >
              {t('board.ability')}
            </button>
            <button
              role="menuitem"
              disabled={!canStrike}
              title={t('board.defendNote')}
              onClick={() => { onDefend(selected.id); setMode(null) }}
            >
              {t('board.defend')}
            </button>
            {/* Only for the unit that is already mid-go. For anyone else there
                is nothing open to close, and submit_wait would end somebody
                else's go instead -- it takes no unit, it ends whichever one
                the server has open. */}
            {(state.active ?? null) === selected.id && (
              <button role="menuitem" onClick={() => { onWait(); setMode(null) }}>
                {t('board.wait')}
              </button>
            )}
            <button
              role="menuitem"
              className="actmenu-cancel"
              onClick={() => { onSelect(null); setMode(null) }}
            >
              {t('board.cancel')}
            </button>
          </div>
        </div>
      )}

      {/* The cinematic. Rendered from here because this is where the board a
          moment ago lives, but it is fixed to the viewport and covers the lot.
          It owns the exchange: the picture, the sound and the words. */}
      {cine && (
        <Duel
          // Keyed by the exchange, so the next one in the queue is a FRESH
          // component rather than the same one handed different props. Without
          // it the scheduling effect would have to unwind a half-played
          // timeline, and `done` would still be latched from the last fight.
          key={cine.seq}
          cine={cine}
          mySide={mySide}
          onDone={endCine}
        />
      )}

      {/* Everything below is transient: it exists only while an exchange plays. */}
      {/* An ability's numbers, one per unit it reached. */}
      {pops.map((h) => {
        const u = state.units.find((x) => x.id === h.id)
        if (!u) return null
        return h.heal !== undefined && h.heal > 0
          ? <div key={h.id} className="dmg dmg-heal" style={at({ x: u.x, y: u.y })}>+{h.heal}</div>
          : <div key={h.id} className="dmg" style={at({ x: u.x, y: u.y })}>-{h.dmg}</div>
      })}

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
            ? <div className="dmg dmg-heal" style={at(blow.tgtAt)}>+{blow.heal}</div>
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
  )
}

type Edge = 'n' | 's' | 'e' | 'w'

/** Which edge of `cell` the neighbouring tile `other` lies across. Both are
 *  DRAWN coordinates -- the arrow is a picture, so it is built in the same
 *  space it is looked at, and the flip has already happened by here. */
function side(other: { x: number; y: number }, cell: { x: number; y: number }): Edge {
  if (other.y < cell.y) return 'n'
  if (other.y > cell.y) return 's'
  if (other.x < cell.x) return 'w'
  return 'e'
}

const EDGE: Record<Edge, [number, number]> = {
  n: [50, 0], s: [50, 100], e: [100, 50], w: [0, 50],
}
/** Which way that edge lies from the middle of the cell. */
const AWAY: Record<Edge, [number, number]> = {
  n: [0, -1], s: [0, 1], e: [1, 0], w: [-1, 0],
}

/**
 * One tile's worth of arrow, in its own grid cell.
 *
 * `from` is the edge the route came in by and `to` the edge it leaves by;
 * either being null is what makes this the tail or the head. Drawing it as
 * "in-edge to middle to out-edge" means the straight piece, the corner, the
 * tail and the shaft of the head are all the same two lines with different
 * ends -- there is no set of sprites to keep consistent with each other.
 *
 * The viewBox is a square and the cells are square, so nothing here is
 * stretched: the arrowhead is the same shape in every cell of the board.
 */
function ArrowPart({ style, from, to }: {
  style: React.CSSProperties
  from: Edge | null
  to: Edge | null
}) {
  const C: [number, number] = [50, 50]
  const pts: [number, number][] = []
  if (from) pts.push(EDGE[from])
  pts.push(C)
  if (to) pts.push(EDGE[to])

  // The head. It points the way the route was travelling, which is away from
  // the edge it arrived by -- so the tip is drawn from `from`, not from `to`,
  // and a route that ends after one step still gets one.
  let head: string | null = null
  if (!to && from) {
    const [ax, ay] = AWAY[from]
    const tx = -ax, ty = -ay                 // the direction of travel
    const px = -ty, py = tx                  // and across it
    const tip: [number, number] = [50 + tx * 34, 50 + ty * 34]
    const base: [number, number] = [50 - tx * 4, 50 - ty * 4]
    head = [tip, [base[0] + px * 21, base[1] + py * 21],
                 [base[0] - px * 21, base[1] - py * 21]]
      .map((q) => q.join(',')).join(' ')
    // Stop the shaft short of the head so the two do not overlap into a blob.
    pts[pts.length - 1] = base
  }

  return (
    <svg className="arrowpart" style={style} viewBox="0 0 100 100" aria-hidden="true">
      <polyline points={pts.map((q) => q.join(',')).join(' ')} />
      {head && <polygon points={head} />}
      {/* A route that has not left the first tile yet still needs something
          at the start, or the arrow appears to begin in mid-air. */}
      {!from && <circle cx="50" cy="50" r="9" />}
    </svg>
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
  thing, style, targetable, shaking, falling, mine, onClick, onHover, onPeek,
}: {
  thing: Obstacle
  style: React.CSSProperties
  targetable: boolean
  shaking: boolean
  falling: boolean
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
                    falling ? 'is-falling' : ''].join(' ')}
        title={t(objNameKey(kind))}
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
 *  colour is set once on the wrapper in CSS and nothing here repeats it. */
function ThingGlyph({ kind }: { kind: ObjKind }) {
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
  unit, slot, yours, watching, selected, target, counters, caught, slotClass, slotVars,
  onClick, onHover, onPeek, slotRef,
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
  slotClass: string
  slotVars?: React.CSSProperties
  onClick: (e: React.MouseEvent) => void
  onHover: (over: boolean) => void
  onPeek: () => void
  slotRef: (el: HTMLDivElement | null) => void
}) {
  const t = useT()
  const press = useLongPress(onPeek)
  const hpPct = Math.max(0, Math.min(100, (unit.hp / unit.maxHp) * 100))
  const marks = afflictionsOf(unit)

  // Literal keys, one branch each. A constructed `t('board.' + m)` is a key no
  // search can find and no i18n check can count, which is the rule the whole
  // dictionary is held to.
  function markTitle(m: Affliction): string {
    if (m === 'burn') return t('board.burning')
    if (m === 'poison') return t('board.poisoned')
    return t('board.stunned')
  }

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
          yours ? 'is-yours' : '',
          watching ? 'is-inert' : '',
          selected ? 'is-selected' : '',
          target ? `is-target is-target-${target}` : '',
          isBurning(unit) ? 'is-burned' : '',
          isPoisoned(unit) ? 'is-poisoned' : '',
          isStunned(unit) ? 'is-stunned' : '',
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

        {/* One row, built from one list, so a mark cannot be drawn without a
            hover title and a mark cannot be added to effects.ts without
            appearing here. The guard goes first because it is the only one of
            the four that the unit itself chose. */}
        {(unit.defending || marks.length > 0) && (
          <div className="unit-marks">
            {unit.defending && (
              <img
                className="unit-mark"
                src={artUrl(MARK_ART.guard)!}
                alt=""
                title={t('board.guarding')}
              />
            )}
            {marks.map((m) => (
              <img
                key={m}
                className="unit-mark"
                src={artUrl(MARK_ART[m])!}
                alt=""
                title={markTitle(m)}
              />
            ))}
          </div>
        )}
        {target === 'ally' && <div className="unit-crosshair is-mend" />}
        {target === 'foe' && <div className={`unit-crosshair${counters ? ' is-risky' : ''}`} />}
      </div>
    </div>
  )
}
