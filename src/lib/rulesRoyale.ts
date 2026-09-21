import type { RoyaleMatchState, RoyaleUnit, Obstacle } from './types'
import { objKind, objSolid, objTramplable } from './objects'

/**
 * The client's copy of the geometry in 0048_battle_royale.sql -- the royale
 * sibling of rules.ts. It decides nothing; every question here is asked
 * again by the matching `cn_*_royale` Postgres function before anything
 * moves, and the answer that counts is that one. This exists so the board
 * can light up squares before you click.
 *
 * If you change a royale rule, change it in the migration first and then
 * here. rules.ts itself is left untouched -- this is a sibling, not an
 * edit to it, so nothing about 1v1 risks moving.
 */

export const rkey = (x: number, y: number) => `${x},${y}`

/** How far apart two tiles are, in movement points: 1 for a cardinal step, 2
 *  for a diagonal one (a corner) -- the royale mirror of rules.ts's own
 *  `cheb`, same 0076 rule, same reason for keeping a name that is no longer
 *  literally Chebyshev distance (see that file's own comment). Unobstructed
 *  this is plain taxicab distance, |dx| + |dy|, since a diagonal step is
 *  worth exactly two cardinal ones and never shortens an open-ground trip. */
export const rcheb = (a: { x: number; y: number }, b: { x: number; y: number }) =>
  Math.abs(a.x - b.x) + Math.abs(a.y - b.y)

/** The 6x8 board split into four 3x4 quadrants -- [x0, x1, y0, y1],
 *  inclusive -- mirrors cn_royale_zone() exactly. */
export function royaleZone(seat: number): [number, number, number, number] | null {
  switch (seat) {
    case 0: return [0, 2, 0, 3]
    case 1: return [3, 5, 0, 3]
    case 2: return [0, 2, 4, 7]
    case 3: return [3, 5, 4, 7]
    default: return null
  }
}

export function ownRoyaleZone(x: number, y: number, seat: number): boolean {
  const z = royaleZone(seat)
  if (!z) return false
  return x >= z[0] && x <= z[1] && y >= z[2] && y <= z[3]
}

export function occupiedRoyale(state: RoyaleMatchState): Set<string> {
  const s = new Set<string>()
  for (const u of state.units) s.add(rkey(u.x, u.y))
  for (const o of state.obstacles ?? []) s.add(rkey(o.x, o.y))
  return s
}

/** Same activation-budget SHAPE as 1v1's canAct (acts/active read off the
 *  royale state the same way) but not the same NUMBER: 0061 gave royale a
 *  flat one-activation cap, every turn, rather than 1v1's "1 on the
 *  opening turn, 2 after" -- a four-seat table was judged to drag at two
 *  each. Mirrors cn_begin_act_royale's own `v_cap := 1` exactly; unlike
 *  before this pass, it no longer calls the shared cn_acts_cap() at all,
 *  so a future change to 1v1's own cap cannot silently drag royale's cap
 *  along with it. */
export function royaleCanAct(state: RoyaleMatchState, u: RoyaleUnit): boolean {
  if (u.spent) return false
  if ((state.active ?? null) === u.id) return true
  const acts = state.acts ?? 0
  const cap = royaleActsCap()
  return acts < cap
}

/** The one number 0061 fixed royale's action budget to. A named export
 *  rather than a literal `1` scattered at each call site, so the UI (the
 *  turn bar's "goes" pips) and the rule above can never drift apart. */
export function royaleActsCap(): number {
  return 1
}

const bodiesR = (state: RoyaleMatchState) => new Set(state.units.map((u) => rkey(u.x, u.y)))
const treesR = (state: RoyaleMatchState) =>
  new Set((state.obstacles ?? []).filter((o) => objSolid(objKind(o))).map((o) => rkey(o.x, o.y)))
const fellableR = (state: RoyaleMatchState) =>
  new Set((state.obstacles ?? []).filter((o) => objTramplable(objKind(o))).map((o) => rkey(o.x, o.y)))

/** The same eight weighted directions as rules.ts's own STEPS -- see that
 *  file's comment for why a diagonal (cost 2) needs relaxation rather than
 *  a plain breadth-first walk once it sits alongside a cardinal (cost 1). */
const RSTEPS: [number, number, number][] = [
  [1, 0, 1], [-1, 0, 1], [0, 1, 1], [0, -1, 1],
  [1, 1, 2], [1, -1, 2], [-1, 1, 2], [-1, -1, 2],
]

/** Every tile a unit can walk to -- the royale mirror of rules.ts's own
 *  reachable(): bounded relaxation against the royale board and unit list,
 *  same bound (u.mov rounds), same reason (two edge costs break BFS's old
 *  "first seen is cheapest" guarantee). No fliers-skip-everything branch,
 *  matching cn_reach()'s current behaviour. */
export function royaleReachable(state: RoyaleMatchState, u: RoyaleUnit): Set<string> {
  const { w, h } = state.board
  const body = bodiesR(state)
  const wood = treesR(state)
  const fell = fellableR(state)
  const blocked = (k: string) => body.has(k) || (wood.has(k) && !(u.tramples && fell.has(k)))

  const start = rkey(u.x, u.y)
  const cost = new Map<string, number>([[start, 0]])

  for (let round = 0; round < u.mov; round++) {
    let changed = false
    for (const [k0, c0] of [...cost]) {
      if (c0 >= u.mov) continue
      const [x0, y0] = k0.split(',').map(Number)
      for (const [dx, dy, wgt] of RSTEPS) {
        const nx = x0 + dx
        const ny = y0 + dy
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
        const nk = rkey(nx, ny)
        if (blocked(nk)) continue
        const nc = c0 + wgt
        if (nc > u.mov) continue
        const cur = cost.get(nk)
        if (cur === undefined || nc < cur) {
          cost.set(nk, nc)
          changed = true
        }
      }
    }
    if (!changed) break
  }

  const out = new Set<string>()
  for (const k of cost.keys()) if (k !== start) out.add(k)
  return out
}

export function royaleLosClear(
  state: RoyaleMatchState,
  a: { x: number; y: number },
  b: { x: number; y: number },
): boolean {
  const den = Math.hypot(b.x - a.x, b.y - a.y)
  if (den === 0) return true
  for (const o of state.obstacles ?? []) {
    if (!objSolid(objKind(o))) continue
    if ((o.x === a.x && o.y === a.y) || (o.x === b.x && o.y === b.y)) continue
    if (o.x < Math.min(a.x, b.x) || o.x > Math.max(a.x, b.x)) continue
    if (o.y < Math.min(a.y, b.y) || o.y > Math.max(a.y, b.y)) continue
    const num = Math.abs((b.x - a.x) * (a.y - o.y) - (a.x - o.x) * (b.y - a.y))
    if (num / den < 0.5) return false
  }
  return true
}

export type RoyaleTarget =
  | { kind: 'foe'; unit: RoyaleUnit }
  | { kind: 'ally'; unit: RoyaleUnit }
  | { kind: 'tree'; tree: Obstacle }

/** Everything the selected unit could act on right now -- any other seat's
 *  unit in range counts as a foe, matching cn_attack_royale's free-for-all
 *  (there is no team play in royale). */
export function royaleTargetsFor(state: RoyaleMatchState, u: RoyaleUnit): Map<string, RoyaleTarget> {
  const out = new Map<string, RoyaleTarget>()
  const inReach = (p: { x: number; y: number }) => {
    const d = rcheb(u, p)
    return d >= u.rmin && d <= u.rmax && royaleLosClear(state, u, p)
  }
  for (const other of state.units) {
    if (other.id === u.id || !inReach(other)) continue
    out.set(other.id, other.owner === u.owner
      ? { kind: 'ally', unit: other } : { kind: 'foe', unit: other })
  }
  for (const t of state.obstacles ?? []) {
    if (inReach(t)) out.set(t.id, { kind: 'tree', tree: t })
  }
  return out
}

/** Where a unit may be placed during deploy: only its own quadrant, minus
 *  what is already standing there. */
export function royaleDeployTiles(state: RoyaleMatchState, seat: number): Set<string> {
  const z = royaleZone(seat)
  const out = new Set<string>()
  if (!z) return out
  const wood = new Set((state.obstacles ?? []).map((o) => rkey(o.x, o.y)))
  for (let y = z[2]; y <= z[3]; y++) {
    for (let x = z[0]; x <= z[1]; x++) if (!wood.has(rkey(x, y))) out.add(rkey(x, y))
  }
  return out
}
