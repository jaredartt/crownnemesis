import { LOG_ICONS } from './logIcons'

/** What a battle-log line is about, for its icon and colour. The server writes
 *  the log as plain English sentences, so this recognises them by shape; a line
 *  it does not know gets a quiet dot. */
export interface LogKind { icon: keyof typeof LOG_ICONS; color: string }

const RED = '#eb5757', ORANGE = '#f2994a', GREEN = '#27ae60', BLUE = '#2f80ed'
const SKY = '#2d9cdb', PURPLE = '#9b51e0', GOLD = '#d4a017', GRAY = '#8a8a98'

const RULES: Array<[RegExp, LogKind]> = [
  [/(-- destroyed\.?|is destroyed\.)$/, { icon: 'skull', color: '#b3261e' }],
  [/ uses Heal|heals? /i, { icon: 'heart-plus', color: GREEN }],
  [/ uses .*bomb/i, { icon: 'bomb', color: ORANGE }],
  [/ uses .*burn/i, { icon: 'flame', color: ORANGE }],
  [/ uses /, { icon: 'sparkles', color: PURPLE }],
  [/ (answers( first)?|strikes again) for /, { icon: 'arrow-back-up', color: ORANGE }],
  [/ hits .* for /, { icon: 'sword', color: RED }],
  [/ lunges at /, { icon: 'arrow-big-right', color: RED }],
  [/ advances\.$/, { icon: 'walk', color: BLUE }],
  [/ pulls back\.$/, { icon: 'arrow-back', color: GRAY }],
  [/ parries /, { icon: 'shield-half', color: SKY }],
  [/ (raises a guard|guards )/, { icon: 'shield', color: SKY }],
  [/ sets down /, { icon: 'bomb', color: ORANGE }],
  [/ burns for /, { icon: 'flame', color: ORANGE }],
  [/cyclone/, { icon: 'tornado', color: SKY }],
  [/ shakes it off/, { icon: 'shield-check', color: GREEN }],
  [/ steps on /, { icon: 'alert-triangle', color: GOLD }],
  [/ran out of time|time ran out|forfeited/, { icon: 'clock-x', color: GOLD }],
  [/ is ready\./, { icon: 'circle-check', color: GREEN }],
  [/^Place your units/, { icon: 'layout-grid', color: GRAY }],
  [/spars with|pairing you with/, { icon: 'users', color: GRAY }],
  [/left the match|resigned/, { icon: 'flag', color: GRAY }],
  [/ wins\.?$/, { icon: 'trophy', color: GOLD }],
  [/crown has fallen/, { icon: 'crown-off', color: RED }],
]

const FALLBACK: LogKind = { icon: 'point', color: GRAY }

export function logKind(text: string): LogKind {
  for (const [re, kind] of RULES) if (re.test(text)) return kind
  return FALLBACK
}

/** "Turn 3 — jaredartt to act." -> { turn: 3, who: 'jaredartt' } */
export function parseTurnLine(text: string): { turn: number; who: string } | null {
  const m = /^Turn (\d+) — (.+) to act\.$/.exec(text)
  return m ? { turn: Number(m[1]), who: m[2] } : null
}

/** Unit-name colours: the same five as the cards and the board's rings. */
export const CLASS_COLORS: Record<string, string> = {
  royal: '#f2994a', rogue: '#27ae60', knight: '#eb5757', mage: '#9b51e0', flying: '#2f80ed',
}

/** Splits a sentence into plain pieces and unit names (with their class). */
export function splitNames(text: string, roles: Map<string, string>): Array<{ text: string; role?: string }> {
  if (roles.size === 0) return [{ text }]
  const names = [...roles.keys()].sort((a, b) => b.length - a.length)
    .map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
  const re = new RegExp(`(?<![\\w&])(${names.join('|')})(?![\\w&])`, 'g')
  const out: Array<{ text: string; role?: string }> = []
  let last = 0
  for (const m of text.matchAll(re)) {
    const at = m.index ?? 0
    if (at > last) out.push({ text: text.slice(last, at) })
    out.push({ text: m[0], role: roles.get(m[0]) ?? '' })
    last = at + m[0].length
  }
  if (last < text.length) out.push({ text: text.slice(last) })
  return out
}
