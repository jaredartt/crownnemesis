import type { AppSettings, Card } from './types'
import { unitPower } from './types'

/**
 * A card's "value": its stats priced with the list on the app_settings row
 * (Admin Mode -> Card value), so a card can be judged at a glance while it is
 * being built. A design aid only -- nothing in a match reads it.
 *
 *   value = hp * vp_per_hp + attack * vp_per_attack + range * vp_per_range
 *         + move * vp_per_move + (the class's own bonus, 0 by default)
 */
export type ValueStatus = 'low' | 'near-low' | 'ok' | 'near-high' | 'high'

type Prices = Pick<AppSettings,
  'vp_per_hp' | 'vp_per_attack' | 'vp_per_range' | 'vp_per_move' | 'vp_class_royal'
  | 'vp_class_rogue' | 'vp_class_knight' | 'vp_class_mage' | 'vp_class_flying' | 'vp_min' | 'vp_max' | 'vp_warn'>

type Stats = Pick<Card, 'hp' | 'mov' | 'range' | 'role' | 'dmin' | 'dmax' | 'power'>

export interface ValueLine { label: string; amount: number; each: number; total: number }

export function classBonus(role: string | null | undefined, s: Prices): number {
  switch (role) {
    case 'royal': return s.vp_class_royal ?? 0
    case 'rogue': return s.vp_class_rogue ?? 0
    case 'knight': return s.vp_class_knight ?? 0
    case 'mage': return s.vp_class_mage ?? 0
    case 'flying': return s.vp_class_flying ?? 0
    default: return 0
  }
}

/** The itemised bill: one line per stat, then the class. */
export function valueLines(c: Stats, s: Prices): ValueLine[] {
  const n = (x: number | null | undefined) => (Number.isFinite(x as number) ? (x as number) : 0)
  const rows: [string, number, number][] = [
    ['HP', n(c.hp), n(s.vp_per_hp)],
    ['Attack', n(unitPower(c)), n(s.vp_per_attack)],
    ['Range', n(c.range), n(s.vp_per_range)],
    ['Move', n(c.mov), n(s.vp_per_move)],
  ]
  const lines = rows.map(([label, amount, each]) => ({ label, amount, each, total: amount * each }))
  const cb = classBonus(c.role, s)
  lines.push({ label: c.role ? `Class (${c.role})` : 'Class', amount: 1, each: cb, total: cb })
  return lines
}

export function cardValue(c: Stats, s: Prices): number {
  const v = valueLines(c, s).reduce((sum, l) => sum + l.total, 0)
  return Math.round(v * 100) / 100
}

/** Red outside min..max; yellow within `vp_warn` of either edge; green otherwise. */
export function valueStatus(v: number, s: Prices): ValueStatus {
  const lo = s.vp_min ?? 0, hi = s.vp_max ?? 0, w = s.vp_warn ?? 0
  if (v < lo) return 'low'
  if (v > hi) return 'high'
  if (v < lo + w) return 'near-low'
  if (v > hi - w) return 'near-high'
  return 'ok'
}

export const statusTone = (st: ValueStatus): 'red' | 'yellow' | 'green' =>
  st === 'low' || st === 'high' ? 'red' : st === 'ok' ? 'green' : 'yellow'
