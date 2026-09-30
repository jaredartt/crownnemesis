import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { Profile, Skin, SkinKind, XpLevel, XpRule, XpSettings } from './types'

/**
 * 0188: the levels/skins catalogs, fetched once and shared -- same shape as
 * useAnimations.ts (a handful of rows that change only when the admin edits
 * them). `refreshProgression()` re-fetches; the admin tab calls it after a save.
 * The skin catalog is also readable synchronously (getSkin) because
 * nameColorStyle() is a plain function used in dozens of render sites.
 */
export interface Progression {
  skins: Skin[]
  levels: XpLevel[]
  rules: XpRule[]
  settings: XpSettings | null
  ready: boolean
}

let state: Progression = { skins: [], levels: [{ level: 1, xp_total: 0 }], rules: [], settings: null, ready: false }
let inflight: Promise<void> | null = null
const listeners = new Set<() => void>()
const bySlug = new Map<string, Skin>()

function publish(next: Progression) {
  state = next
  bySlug.clear()
  for (const s of next.skins) bySlug.set(`${s.kind}:${s.slug}`, s)
  listeners.forEach((l) => l())
}

export function refreshProgression(): Promise<void> {
  if (!inflight) {
    inflight = (async () => {
      const [sk, lv, ru, se] = await Promise.all([
        supabase.from('skins').select('*').eq('is_active', true).order('sort'),
        supabase.from('xp_levels').select('*').order('level'),
        supabase.from('xp_rules').select('*').order('sort'),
        supabase.from('xp_settings').select('*').eq('id', 1).maybeSingle(),
      ])
      inflight = null
      if (sk.error || lv.error) { console.warn('progression:', sk.error?.message ?? lv.error?.message); return }
      publish({
        skins: (sk.data ?? []) as Skin[],
        levels: ((lv.data ?? []) as XpLevel[]).length ? (lv.data as XpLevel[]) : state.levels,
        rules: (ru.data ?? []) as XpRule[],
        settings: (se.data ?? null) as XpSettings | null,
        ready: true,
      })
    })()
  }
  return inflight
}

export function useProgression(): Progression {
  const [, bump] = useState(0)
  useEffect(() => {
    const l = () => bump((n) => n + 1)
    listeners.add(l)
    if (!state.ready) void refreshProgression()
    return () => { listeners.delete(l) }
  }, [])
  return state
}

/** Synchronous lookup for render helpers; undefined until the catalog has loaded. */
export function getSkin(kind: SkinKind, slug: string | null | undefined): Skin | undefined {
  return slug ? bySlug.get(`${kind}:${slug}`) : undefined
}

export interface LevelInfo {
  level: number
  /** XP earned inside this level. */
  into: number
  /** XP the level is worth (to the next one); null at the top level. */
  span: number | null
  /** 0..1 progress to the next level (1 at the top). */
  pct: number
  nextAt: number | null
}

export function levelInfo(levels: XpLevel[], xp: number | undefined | null): LevelInfo {
  const x = Math.max(0, xp ?? 0)
  const sorted = [...levels].sort((a, b) => a.level - b.level)
  let cur = sorted[0] ?? { level: 1, xp_total: 0 }
  for (const l of sorted) if (l.xp_total <= x) cur = l
  const next = sorted.find((l) => l.level > cur.level) ?? null
  const span = next ? next.xp_total - cur.xp_total : null
  return {
    level: cur.level,
    into: x - cur.xp_total,
    span,
    pct: span && span > 0 ? Math.min(1, (x - cur.xp_total) / span) : 1,
    nextAt: next ? next.xp_total : null,
  }
}

/** The signed-in player's skin grants from outside the level track. */
export function useMyGrants(userId: string | undefined, refreshKey = 0): Set<string> {
  const [ids, setIds] = useState<Set<string>>(new Set())
  useEffect(() => {
    if (!userId) return
    let alive = true
    supabase.from('user_skins').select('skin_id').eq('user_id', userId).then(({ data }) => {
      if (alive && data) setIds(new Set((data as { skin_id: string }[]).map((r) => r.skin_id)))
    })
    return () => { alive = false }
  }, [userId, refreshKey])
  return ids
}

export function ownsSkin(skin: Skin, level: number, grants: Set<string>): boolean {
  return grants.has(skin.id) || (skin.unlock_level != null && level >= skin.unlock_level)
}

export function skinLabel(skin: Skin, lang: string): string {
  return (lang === 'es' && skin.name_es) || skin.name
}

export function levelOfProfile(p: Pick<Profile, 'xp'> | null | undefined): number {
  return levelInfo(state.levels, p?.xp ?? 0).level
}
