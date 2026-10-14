import type { Card, MatchState, Unit } from './types'
import { cheb, hitCapped } from './rules'
import { objKind } from './objects'

/**
 * Abilities that are a STATE rather than an event.
 *
 * Jared: "Umiro's ability is a constant thing. Make it so the animation on top
 * of the tokens in range 1 is constant until they leave Umiro, and if they come
 * back, they have it constant again -- even if it's the other person's turn.
 * Do it for all other abilities that may be constant."
 *
 * Everything else the board animates is a one-shot played when the server
 * reports that something HAPPENED (fx.anims). A standing effect is never
 * reported, because nothing happened: it is simply true of the board. So this
 * reads the board itself, every render, and answers "which animation should be
 * looping on which unit right now". The caller mounts each answer with a
 * stable key, so the loop keeps playing for exactly as long as the condition
 * holds, vanishes the moment it stops, and starts fresh if it holds again --
 * regardless of whose turn it is.
 *
 * Which animation is NOT decided here: it is the `animation_slug` already
 * written on the card's own effect row in Admin, so retuning or swapping one
 * stays soft-coded. Only the "when is it on" test lives in code, because that
 * is the rule the server enforces and the two have to agree.
 *
 *   NEARBY_POWER      Umiro: every ally within range of him (Manhattan, like
 *                     rules.ts's nearPower, which it mirrors).
 *   POWER / CRIT_PCT  Wuzu's surge, Dereo's rally: any unit whose live stat is
 *                     above its card's printed one, on the unit(s) the row
 *                     targets (SELF or ALL_ALLIES).
 *   MAX_HITS_PER_TURN Leos: while he has taken his one hit this turn.
 *   TREE_SHIELD       Shu: while a tree stands within range of her.
 *
 * Always-on traits that never switch (Nara's ward, Lium's mirror, Dorme's
 * counter-ward, Himanta's stars) are deliberately NOT here: a loop that never
 * stops on a unit that never changes is noise, not information.
 */
export type Ambient = { key: string; slug: string; x: number; y: number }

type BaseOf = (slug: string) => Pick<Card, 'power' | 'crit_pct' | 'parry_pct'> | undefined

export function ambientFx(state: MatchState, baseOf: BaseOf): Ambient[] {
  if (state.phase !== 'battle') return []
  const out = new Map<string, Ambient>()
  const put = (slug: string, u: Unit, tag: string) => {
    // One loop per (animation, unit): two Umiros must not stack two copies.
    out.set(`${slug}|${u.id}`, { key: `amb-${tag}-${slug}-${u.id}`, slug, x: u.x, y: u.y })
  }
  const alive = state.units.filter((u) => u.hp > 0)
  for (const src of alive) {
    for (const r of src.abilityScript ?? []) {
      const slug = r.animation_slug
      if (!slug || r.action !== 'MODIFY_STAT') continue
      const stat = r.stat_name
      if (stat === 'NEARBY_POWER' && r.trigger === 'PASSIVE') {
        const max = r.range_kind === 'FIXED_RANGE' ? (r.range_max ?? 1) : 1
        for (const u of alive) {
          if (u.id === src.id || u.owner !== src.owner) continue
          const d = Math.abs(src.x - u.x) + Math.abs(src.y - u.y)
          if (d >= 1 && d <= max) put(slug, u, 'near')
        }
      } else if (stat === 'POWER' || stat === 'CRIT_PCT') {
        const who = r.target_selector === 'ALL_ALLIES' ? alive.filter((u) => u.owner === src.owner)
          : r.target_selector === 'SELF' ? [src] : []
        for (const u of who) {
          const base = baseOf(u.slug)
          if (!base) continue
          const up = stat === 'POWER'
            ? (u.pow ?? 0) > (base.power ?? Infinity)
            : (u.critPct ?? 0) > (base.crit_pct ?? Infinity)
          if (up) put(slug, u, 'stat')
        }
      } else if (stat === 'MAX_HITS_PER_TURN' && r.trigger === 'PASSIVE') {
        if (hitCapped(state, src)) put(slug, src, 'cap')
      } else if (stat === 'TREE_SHIELD' && r.trigger === 'PASSIVE') {
        const max = r.range_kind === 'FIXED_RANGE' ? (r.range_max ?? 1) : 1
        if ((state.obstacles ?? []).some((o) => o.hp > 0 && objKind(o) === 'tree' && cheb(o, src) <= max)) {
          put(slug, src, 'tree')
        }
      }
    }
  }
  return [...out.values()]
}
