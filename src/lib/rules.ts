import { actsCap, type MatchState, type Obstacle, type Side, type Unit } from './types'
import { objKind, objSolid, objTramplable } from './objects'
import { awake } from './swamp'

/**
 * The client's copy of the geometry in 0005_roster_terrain_deploy.sql.
 *
 * It decides nothing. Every one of these questions is asked again by the
 * Postgres function before anything moves, and the answer that counts is that
 * one. This exists so the board can light up the squares you may use BEFORE
 * you click, which is the whole difference between a tactics game and a
 * guessing game.
 *
 * If you change a rule, change it in the migration first and then here.
 */

export const key = (x: number, y: number) => `${x},${y}`

/**
 * How far apart two tiles are, in movement points: 1 for a cardinal step, 2
 * for a diagonal one (a corner). A diagonal is worth exactly two cardinal
 * steps, never less, so unobstructed this collapses to a closed form --
 * |dx| + |dy|, plain taxicab distance -- with no need to walk it out the
 * way reachable()/pathTo() do; range never looks at what's in between
 * anyway (see losClear for that). Kept the name `cheb` despite no longer
 * being Chebyshev distance: attacks, counters, and every range check in
 * Board.tsx and swamp.ts call it by that name, and renaming it here without
 * renaming cn_cheb() in the 0076 migration (kept there for the same reason,
 * at roughly ninety call sites) would leave the two halves of one rule
 * calling each other by different names for no reason a reader could see.
 */
export const cheb = (a: { x: number; y: number }, b: { x: number; y: number }) =>
  Math.abs(a.x - b.x) + Math.abs(a.y - b.y)

/** The host holds the top of the board, the guest the bottom: on an 8-tall
 *  board that is rows 0-3 and rows 4-7. Mirrors cn_own_side() in 0019, whose
 *  arguments mean y and h where 0011's meant x and w.
 *
 *  Note that this asks about SERVER coordinates, which is the only kind there
 *  is -- the flip below is a drawing, and nothing in the rules knows about it. */
export const ownSide = (side: Side, y: number, h: number) =>
  side === 'host' ? y < Math.floor(h / 2) : y >= Math.floor(h / 2)

/**
 * Where a tile is DRAWN.
 *
 * The server keeps one set of coordinates and 0019 gave the halves back to the
 * rows, so the host's ground is the top of that one board and the guest's is
 * the bottom. Rather than rotate anything in the database -- which is what
 * 0011 was trying to avoid and what cost it the halves in the first place --
 * the guest's client turns the picture half a turn, so whoever is looking is
 * always at the bottom looking up.
 *
 * A half turn, and not a mirror: flipping only the rows would leave left and
 * right where they were, and a spearman who advanced up the right of the board
 * for the host would be advancing up the LEFT of it for the guest. Board
 * coordinates go in, screen coordinates come out, and the two are only ever
 * converted here.
 */
export const draw = (
  p: { x: number; y: number }, w: number, h: number, flip: boolean,
) => (flip ? { x: w - 1 - p.x, y: h - 1 - p.y } : { x: p.x, y: p.y })

/**
 * Who turns the board over.
 *
 * The HOST does. It reads backwards until you check which rows are whose:
 * cn_own_side gives the host rows 0-3, so drawn straight the host's army sits
 * along the TOP and the guest's along the bottom -- and the guest is already
 * where they should be. It is the host who has to turn the picture over to be
 * at the bottom of it.
 *
 * A spectator turns nothing. They have no ground to be near, and leaving the
 * board as the server holds it means the one picture nobody is playing in is
 * also the one that matches the coordinates in the log.
 *
 * Board.tsx draws from this and Match.tsx sides a hovered tree's card from it,
 * which is the whole reason it is a named rule here rather than a comparison
 * written out twice.
 */
export const flipFor = (side: Side | null) => side === 'host'

/** draw() is its own inverse -- turning a board half a turn twice puts it back
 *  -- so the same call converts a screen tile back into a board tile. Named
 *  separately because a reader should not have to work that out at the call
 *  site, and because it stops being true the day the flip becomes anything but
 *  a half turn. */
export const undraw = draw

/** And the sign a direction picks up on the way through it. A lunge to the
 *  east is drawn as a lunge to the west on a flipped board. */
export const drawSign = (flip: boolean) => (flip ? -1 : 1)

/**
 * May this unit start -- or carry on -- a go right now? Mirrors cn_begin_act()
 * in 0019, minus the ownership checks the caller has already made.
 *
 * The unit already mid-go always may, and that is the whole subtlety: it moved
 * a moment ago and is now striking, which is the same activation and costs
 * nothing further. Everybody else needs a spare one in the turn's budget.
 */
export function canAct(state: MatchState, u: Unit): boolean {
  if (u.spent) return false
  if ((state.active ?? null) === u.id) return true
  return (state.acts ?? 0) < actsCap(state)
}

export function occupied(state: MatchState): Set<string> {
  const s = new Set<string>()
  for (const u of state.units) s.add(key(u.x, u.y))
  for (const o of state.obstacles ?? []) s.add(key(o.x, o.y))
  return s
}

const bodies = (state: MatchState) => new Set(state.units.map((u) => key(u.x, u.y)))
/** Tiles nothing can walk through or shoot through. Since 0035 that is not
 *  every object: a trap and a tornado are stood on, not walked around. The
 *  name is kept because the shape of the walk below is unchanged. */
const trees = (state: MatchState) =>
  new Set((state.obstacles ?? []).filter((o) => objSolid(objKind(o)))
    .map((o) => key(o.x, o.y)))
/** ...and of those, the ones a trampler may walk through, which is trees. */
const fellable = (state: MatchState) =>
  new Set((state.obstacles ?? []).filter((o) => objTramplable(objKind(o)))
    .map((o) => key(o.x, o.y)))

/** The eight directions a step can take, paired with its cost: a cardinal
 *  step is one point, a diagonal one -- a corner -- is two. A diagonal is
 *  worth exactly twice a cardinal step, never less, so on open ground it
 *  never shortens a trip -- two cardinal steps buy the same displacement for
 *  the same two points. What it buys instead is a way THROUGH A CORNER that
 *  cardinal steps alone cannot take at all: when a tile's two cardinal
 *  neighbours are both blocked but the tile itself is not, the diagonal step
 *  onto it is the only route there. Mirrors 0076's v_dx/v_dy/v_dw exactly. */
const STEPS: [number, number, number][] = [
  [1, 0, 1], [-1, 0, 1], [0, 1, 1], [0, -1, 1],
  [1, 1, 2], [1, -1, 2], [-1, 1, 2], [-1, -1, 2],
]

/**
 * The weighted walk reachable() and pathTo() both build on -- one shared
 * core rather than two copies that could quietly drift apart, now that a
 * route's cost depends on WHICH tiles it crosses and not merely how many.
 *
 * Every edge used to cost the same single point, so a plain breadth-first
 * walk was enough: the first time you saw a tile was, by definition, the
 * cheapest way to it. Two different edge costs break that guarantee -- a
 * tile can be FOUND by an expensive route before a cheaper one to it turns
 * up, so "seen" and "cheapest" stop being the same question. The fix is not
 * a full Dijkstra with a priority queue, which would be overkill for a board
 * this size, but the bounded relaxation Bellman-Ford uses: every edge costs
 * at least 1, so any route that stays inside u.mov crosses at most u.mov of
 * them, and u.mov full passes over every tile reached so far -- each one
 * relaxing that tile's up-to-eight neighbours -- is guaranteed to have
 * settled everyone's true cheapest cost by the end. Mirrors cn_reach() in
 * the 0076 migration exactly, including that same bound.
 *
 * FLIGHT IS NOT A PASS -- since 0038 a flier walks this exact same weighted
 * grid as everybody else rather than skipping straight to a landing tile. A
 * trampler walks it too, but a tree is ground to it, and comes down when it
 * stops there.
 *
 * ONLY `pathTo()` cares which SPECIFIC cheapest route wins a tie -- and does,
 * now: a diagonal step costs exactly what two cardinal ones covering the
 * same displacement cost, so open ground is thick with equal-cost routes
 * that either do or do not cut a corner, and the mover's own client never
 * sends a route to the server anyway (submitMove ships only the destination
 * tile; cn_move revalidates cost against the board itself). Nothing here
 * changes WHICH tiles are reachable or at what cost -- `reachable()` and
 * cn_reach() do not even look at `diag` -- only which of several
 * equally-cheap paths pathTo() hands back to draw as the preview arrow, so
 * that arrow reads as "the way you'd actually walk it" instead of an
 * arbitrary corner cut through open air. See `diag`, below, for the tie
 * itself.
 */
function walk(state: MatchState, u: Unit) {
  const { w, h } = state.board
  const body = bodies(state)
  const wood = trees(state)
  const fell = fellable(state)
  const blocked = (k: string) =>
    body.has(k) || (wood.has(k) && !(u.tramples && fell.has(k)))

  const start = key(u.x, u.y)
  const cost = new Map<string, number>([[start, 0]])
  const from = new Map<string, string | null>([[start, null]])
  // How many of the steps on the cheapest known route to this tile were
  // diagonal ones. Cost alone leaves ties: two cardinal steps buy the same
  // displacement as one diagonal for the same two points, so open ground is
  // full of routes that cost exactly the same whether or not they ever cut
  // a corner. Left to itself, Bellman-Ford keeps whichever of those happens
  // to relax first -- which the diagonal STEPS entries sometimes did purely
  // because of iteration order, drawing (and would have walked) a corner cut
  // through open ground for no reason, with nothing to actually show for
  // it. `diag` breaks that tie the way a player actually thinks about it:
  // among routes of equal cost, prefer the one with fewer diagonal steps,
  // so a diagonal only ever appears in the result when it is genuinely
  // buying something -- a corner around a blocked tile -- never as an
  // arbitrary stand-in for two cardinal steps it ties with.
  const diag = new Map<string, number>([[start, 0]])

  for (let round = 0; round < u.mov; round++) {
    let changed = false
    for (const [k0, c0] of [...cost]) {
      if (c0 >= u.mov) continue
      const [x0, y0] = k0.split(',').map(Number)
      const d0 = diag.get(k0) ?? 0
      for (const [dx, dy, wgt] of STEPS) {
        const nx = x0 + dx
        const ny = y0 + dy
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
        const nk = key(nx, ny)
        if (blocked(nk)) continue
        const nc = c0 + wgt
        if (nc > u.mov) continue
        const nd = d0 + (wgt === 2 ? 1 : 0)
        const cur = cost.get(nk)
        const curDiag = diag.get(nk) ?? Infinity
        // Strictly cheaper always wins, exactly as before. Tied with the
        // current best is new territory: it only wins by using fewer
        // diagonals, never merely by arriving in a later round.
        if (cur === undefined || nc < cur || (nc === cur && nd < curDiag)) {
          cost.set(nk, nc)
          from.set(nk, k0)
          diag.set(nk, nd)
          changed = true
        }
      }
    }
    if (!changed) break
  }
  return { cost, from }
}

/** Every tile a unit can walk to. Mirrors cn_reach() in the 0076 migration
 *  -- see walk() above for the algorithm and why it changed. */
export function reachable(state: MatchState, u: Unit): Set<string> {
  const { cost } = walk(state, u)
  const start = key(u.x, u.y)
  const out = new Set<string>()
  for (const k of cost.keys()) if (k !== start) out.add(k)
  return out
}

/**
 * The route a unit would actually walk to get there, as the tiles it stands on,
 * starting with the one it is on now and ending on the target.
 *
 * reachable() answers WHETHER; this answers HOW, and the two have to agree or
 * the arrow will promise a road the server refuses -- so both are now thin
 * wrappers over the same walk() above, keeping a predecessor for each tile
 * instead of only the fact that it was reached.
 *
 * Null when the tile is not reachable at all -- the caller should not be
 * asking, but a hover can outrun a state update by a frame.
 */
export function pathTo(
  state: MatchState, u: Unit, tx: number, ty: number,
): { x: number; y: number }[] | null {
  if (tx === u.x && ty === u.y) return null
  const { from, cost } = walk(state, u)
  const end = key(tx, ty)
  if (!cost.has(end)) return null
  const out: { x: number; y: number }[] = []
  for (let at: string | null = end; at !== null; at = from.get(at) ?? null) {
    const [x, y] = at.split(',').map(Number)
    out.unshift({ x, y })
  }
  return out
}

/**
 * Is a tree standing in the shot? A tree blocks if its centre lies within half
 * a tile of the straight line between the two. Units never block -- you can
 * shoot past your own people, you just cannot shoot through wood.
 */
export function losClear(
  state: MatchState,
  a: { x: number; y: number },
  b: { x: number; y: number },
): boolean {
  const den = Math.hypot(b.x - a.x, b.y - a.y)
  if (den === 0) return true
  for (const o of state.obstacles ?? []) {
    // You shoot straight over a trap and over a tornado. Mirrors the same
    // `continue` in cn_los_clear.
    if (!objSolid(objKind(o))) continue
    if ((o.x === a.x && o.y === a.y) || (o.x === b.x && o.y === b.y)) continue
    if (o.x < Math.min(a.x, b.x) || o.x > Math.max(a.x, b.x)) continue
    if (o.y < Math.min(a.y, b.y) || o.y > Math.max(a.y, b.y)) continue
    const num = Math.abs((b.x - a.x) * (a.y - o.y) - (a.x - o.x) * (b.y - a.y))
    if (num / den < 0.5) return false
  }
  return true
}

export type Target =
  | { kind: 'foe'; unit: Unit }
  | { kind: 'ally'; unit: Unit }
  | { kind: 'tree'; tree: Obstacle }

/** Everything the selected unit could act on right now. */
export function targetsFor(state: MatchState, u: Unit): Map<string, Target> {
  const out = new Map<string, Target>()
  const inReach = (p: { x: number; y: number }) => {
    const d = cheb(u, p)
    return d >= u.rmin && d <= u.rmax && losClear(state, u, p)
  }
  for (const other of state.units) {
    if (other.id === u.id || !inReach(other)) continue
    // FRIENDLY FIRE IS ALLOWED since 0038: an ally in reach is a target for
    // everybody, not only for a healer. What `kind: 'ally'` means here is
    // "one of yours" and nothing more -- whether that is a mend or a blow is
    // decided by whether the unit heals, and the board draws the crosshair
    // accordingly. Nothing on the roster heals, so today it is always a blow.
    out.set(other.id, other.owner === u.owner
      ? { kind: 'ally', unit: other } : { kind: 'foe', unit: other })
  }
  for (const t of state.obstacles ?? []) {
    if (inReach(t)) out.set(t.id, { kind: 'tree', tree: t })
  }
  return out
}

/**
 * Everything the selected unit could DEFEND right now -- self, any unit
 * (ally or enemy), or any structure, so long as it sits at Chebyshev
 * distance <= 1. Jared: "This applies to any unit, any movement or range
 * they may have, it's all ignored: if you want to defend anything, it needs
 * to be in range 1." Deliberately NOT `targetsFor`'s own `inReach` (which
 * gates on the unit's own rmin/rmax and line of sight) -- defend ignores
 * both, mirroring cn_defend's server-side check (cn_cheb <= 1, nothing
 * else). Self is always included, at distance 0.
 *
 * Jared, later: "make it not possible to defend an already defended unit,
 * since players would be wasting their turn -- already defended units will
 * not appear as targets." So this filters out anything already carrying
 * `defending`, self included -- there is nothing a second guard would add
 * that the first one is not already doing, so it is never a real choice,
 * only a way to burn a turn by accident.
 */
export function defendTargetsFor(state: MatchState, u: Unit): Map<string, Target> {
  const out = new Map<string, Target>()
  const inReach = (p: { x: number; y: number }) => cheb(u, p) <= 1

  if (!u.defending) out.set(u.id, { kind: 'ally', unit: u })
  for (const other of state.units) {
    if (other.id === u.id || other.defending || !inReach(other)) continue
    out.set(other.id, other.owner === u.owner
      ? { kind: 'ally', unit: other } : { kind: 'foe', unit: other })
  }
  for (const t of state.obstacles ?? []) {
    if (!t.defending && inReach(t)) out.set(t.id, { kind: 'tree', tree: t })
  }
  return out
}

/** Would this target hit back? Purely informational, for the hover hint. */
export function willCounter(u: Unit, t: Target): boolean {
  if (t.kind !== 'foe') return false
  if (u.sneaks) return false
  const d = cheb(u, t.unit)
  return d >= t.unit.crmin && d <= t.unit.crmax
}

/**
 * The same two warnings, asked of the board rather than of two loose units --
 * which is what they have to be since 0037, because whether that Dorme answers
 * first depends on who is standing NEXT to it. Board.tsx calls these; the pair
 * above are left alone so nothing that only has two units in hand breaks.
 */
export function willCounterOn(state: MatchState, u: Unit, t: Target): boolean {
  if (t.kind !== 'foe') return false
  return willCounter(awake(state, u), { ...t, unit: awake(state, t.unit) })
}

export function willParryOn(state: MatchState, u: Unit, t: Target): boolean {
  if (t.kind !== 'foe') return false
  const a = awake(state, u)
  const b = awake(state, t.unit)
  return willCounter(a, { ...t, unit: b }) && b.parries
}

/** And would it hit back FIRST? A parry lands before the blow it answers, so
 *  a unit that cannot survive it should not swing at all -- which is a
 *  different warning from "this will cost you something". */
export function willParry(u: Unit, t: Target): boolean {
  return willCounter(u, t) && t.kind === 'foe' && t.unit.parries
}

/** Where a unit may stand during deployment: your half, minus what is there. */
export function deployTiles(state: MatchState, side: Side): Set<string> {
  const { w, h } = state.board
  const wood = new Set((state.obstacles ?? []).map((o) => key(o.x, o.y)))
  const out = new Set<string>()
  for (let y = 0; y < h; y++) {
    if (!ownSide(side, y, h)) continue
    for (let x = 0; x < w; x++) if (!wood.has(key(x, y))) out.add(key(x, y))
  }
  return out
}
