import type { Profile } from './types'

/**
 * The achievement catalog -- a fixed, closed list, not a database table.
 *
 * Unlock STATE lives in `player_achievements` (0045_achievements.sql), which
 * a match server-side genuinely changes; the catalog itself -- names, icons,
 * thresholds -- has never had a reason to change without a deploy, so it is
 * a constant here rather than a table an admin screen would need to grow.
 *
 * Four counters, seven tiers apiece, plus four one-off "single-class team"
 * achievements that fire once. `id` is the exact string cn_check_achievements
 * and cn_attack insert into player_achievements -- change one side without
 * the other and a real unlock stops matching a real badge.
 */

export type AchievementCounterKey = 'bot_wins' | 'ranked_wins' | 'crit_count' | 'parry_count'

export interface AchievementDef {
  id: string
  /** A single glyph -- emoji, kept consistent with the rest of the roster's
   *  plain, line-drawing style rather than a photographic icon set. */
  icon: string
  /** i18n key. Tiered achievements share ONE key across all seven of their
   *  tiers and fill {n} with the threshold at render time -- see i18n.ts's
   *  own rule against building a key out of a variable; this is the other
   *  way to stay data-driven without ever constructing one. */
  nameKey: string
  descKey: string
  /** Set only on a tiered achievement. */
  threshold?: number
  counterKey?: AchievementCounterKey
}

const TIERS = [1, 10, 20, 100, 200, 500, 1000] as const

function tierSet(
  prefix: string, counterKey: AchievementCounterKey, icon: string,
  nameKey: string, descKey: string,
): AchievementDef[] {
  return TIERS.map((n) => ({ id: `${prefix}_${n}`, icon, threshold: n, counterKey, nameKey, descKey }))
}

export const ACHIEVEMENTS: AchievementDef[] = [
  ...tierSet('bot_wins', 'bot_wins', '\u{1F916}', 'achievement.botWins.name', 'achievement.botWins.desc'),
  ...tierSet('ranked_wins', 'ranked_wins', '\u{1F3C6}', 'achievement.rankedWins.name', 'achievement.rankedWins.desc'),
  ...tierSet('crits', 'crit_count', '⚡', 'achievement.crits.name', 'achievement.crits.desc'),
  ...tierSet('parries', 'parry_count', '\u{1F6E1}', 'achievement.parries.name', 'achievement.parries.desc'),
  { id: 'single_class_knight', icon: '⚔️',
    nameKey: 'achievement.singleClassKnight.name', descKey: 'achievement.singleClassKnight.desc' },
  { id: 'single_class_rogue', icon: '\u{1F5E1}️',
    nameKey: 'achievement.singleClassRogue.name', descKey: 'achievement.singleClassRogue.desc' },
  { id: 'single_class_mage', icon: '\u{1F52E}',
    nameKey: 'achievement.singleClassMage.name', descKey: 'achievement.singleClassMage.desc' },
  { id: 'single_class_flying', icon: '\u{1FAB6}',
    nameKey: 'achievement.singleClassFlying.name', descKey: 'achievement.singleClassFlying.desc' },
]

export const ACHIEVEMENTS_BY_ID: Map<string, AchievementDef> = new Map(
  ACHIEVEMENTS.map((a) => [a.id, a]),
)

/** How close a profile is to a tiered achievement's threshold. Null for a
 *  one-off, which either is or is not unlocked and has no "247/500" to show. */
export function achievementProgress(
  a: AchievementDef,
  profile: Pick<Profile, 'bot_wins' | 'ranked_wins' | 'crit_count' | 'parry_count'>,
): { current: number; threshold: number } | null {
  if (!a.counterKey || a.threshold == null) return null
  return { current: profile[a.counterKey] ?? 0, threshold: a.threshold }
}
