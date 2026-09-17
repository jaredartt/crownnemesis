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

export const rcheb = (a: { x: number; y: number }, b: { x: number; y: number }) =>
  Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y))

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

/** Every tile a unit can walk to -- same breadth-first walk as rules.ts's
 *  reachable(), against the royale board and unit list. No fliers-skip-
 *  everything branch, matching cn_reach()'s current behaviour. */
export function royaleReachable(state: RoyaleMatchState, u: RoyaleUnit): Set<string> {
  const { w, h } = state.board
  const body = bodiesR(state)
  const wood = treesR(state)
  const fell = fellableR(state)
  const blocked = (k: string) => body.has(k) || (wood.has(k) && !(u.tramples && fell.has(k)))
  const out = new Set<string>()
  const seen = new Set<string>([rkey(u.x, u.y)])
  let front: { x: number; y: number }[] = [{ x: u.x, y: u.y }]

  for (let step = 0; step < u.mov && front.length; step++) {
    const next: { x: number; y: number }[] = []
    for (const p of front) {
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const nx = p.x + dx
        const ny = p.y + dy
        const k = rkey(nx, ny)
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
