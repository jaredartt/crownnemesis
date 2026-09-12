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

/** Reach counts a diagonal as one step. Attacks and counters use this. */
export const cheb = (a: { x: number; y: number }, b: { x: number; y: number }) =>
  Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y))

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

/**
 * Every tile a unit can walk to. A breadth-first walk of the grid, not a
 * distance test: movement is orthogonal and a tree has to be walked around,
 * so the shape is a diamond with bites taken out of it.
 *
 * Two units ask a different question. A flier is not walking, so nothing on
 * the ground is consulted except the tile it means to land on. A trampler
 * walks the same grid as everybody else, but a tree is ground to it -- and
 * the tree comes down when it stops there. Both are mirrored from cn_reach()
 * in 0010_roster.sql.
 */
export function reachable(state: MatchState, u: Unit): Set<string> {
  const { w, h } = state.board
  const body = bodies(state)
  const wood = trees(state)
  const out = new Set<string>()

  if (u.flies) {
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const d = Math.abs(x - u.x) + Math.abs(y - u.y)
        const k = key(x, y)
        if (d >= 1 && d <= u.mov && !body.has(k) && !wood.has(k)) out.add(k)
      }
    }
    return out
  }

  const fell = fellable(state)
  const blocked = (k: string) =>
    body.has(k) || (wood.has(k) && !(u.tramples && fell.has(k)))
  const seen = new Set<string>([key(u.x, u.y)])
  let front: { x: number; y: number }[] = [{ x: u.x, y: u.y }]

  for (let step = 0; step < u.mov && front.length; step++) {
    const next: { x: number; y: number }[] = []
    for (const p of front) {
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const nx = p.x + dx
        const ny = p.y + dy
        const k = key(nx, ny)
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
        if (seen.has(k) || blocked(k)) continue
        seen.add(k)
        out.add(k)
        next.push({ x: nx, y: ny })
      }
    }
    front = next
  }
  return out
}

/**
 * The route a unit would actually walk to get there, as the tiles it stands on,
 * starting with the one it is on now and ending on the target.
 *
 * reachable() answers WHETHER; this answers HOW, and the two have to agree or
 * the arrow will promise a road the server refuses. So it is the same walk --
 * same orthogonal steps, same blocking, same breadth-first order -- keeping a
 * predecessor for each tile instead of only the fact that it was seen. Breadth
 * first means the first route found to a tile is a shortest one, which is the
 * one to draw.
 *
 * A flier is not walking. It goes over everything in the way, so the honest
 * picture is the straight hop: where it stands, and where it lands.
 *
 * Null when the tile is not reachable at all -- the caller should not be
 * asking, but a hover can outrun a state update by a frame.
 */
export function pathTo(
  state: MatchState, u: Unit, tx: number, ty: number,
): { x: number; y: number }[] | null {
  if (tx === u.x && ty === u.y) return null
  if (u.flies) {
    return reachable(state, u).has(key(tx, ty))
      ? [{ x: u.x, y: u.y }, { x: tx, y: ty }]
      : null
  }

  const { w, h } = state.board
  const body = new Set(state.units.map((v) => key(v.x, v.y)))
  const wood = trees(state)
  const fell = fellable(state)
  const blocked = (k: string) =>
    body.has(k) || (wood.has(k) && !(u.tramples && fell.has(k)))

  const from = new Map<string, string | null>([[key(u.x, u.y), null]])
  let front = [{ x: u.x, y: u.y }]
  for (let step = 0; step < u.mov && front.length; step++) {
    const next: { x: number; y: number }[] = []
    for (const p of front) {
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const nx = p.x + dx
        const ny = p.y + dy
        const k = key(nx, ny)
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
        if (from.has(k) || blocked(k)) continue
        from.set(k, key(p.x, p.y))
        next.push({ x: nx, y: ny })
      }
    }
    front = next
  }

  const end = key(tx, ty)
  if (!from.has(end)) return null
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
    if (other.owner === u.owner) {
      if (u.heals) out.set(other.id, { kind: 'ally', unit: other })
    } else {
      out.set(other.id, { kind: 'foe', unit: other })
    }
  }
  for (const t of state.obstacles ?? []) {
    if (inReach(t)) out.set(t.id, { kind: 'tree', tree: t })
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
