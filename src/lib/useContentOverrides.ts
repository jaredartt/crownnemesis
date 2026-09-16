/**
 * Every admin-overridden i18n string, live from the database. See
 * 0046_admin_content_and_delete.sql for menu_content_overrides itself, and
 * the design note at the top of that file for why this exists alongside
 * menu_sections' own title/subtitle columns rather than instead of them.
 *
 * Same cache/listener/Realtime shape as useMenuSections.ts, with one thing
 * added: src/lib/i18n.ts's `t()` is a plain function, not a hook, and it
 * needs to read whatever this cache holds RIGHT NOW, synchronously, on every
 * call -- there is no render to hang a subscription off of. `getOverride()`
 * is that synchronous read, kept in step with the same rows the hook and the
 * admin screen see, and `subscribeOverrideChanges()` is how i18n.ts's own
 * `version` counter gets bumped when a fresh row lands, so a screen already
 * on-screen re-renders with the new words the same way it does for a
 * language switch.
 */
import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { ContentOverride } from './types'
import type { Lang } from './i18n'

let cache: ContentOverride[] | null = null
let inflight: Promise<ContentOverride[]> | null = null
const listeners = new Set<(rows: ContentOverride[]) => void>()

/** The synchronous half: key -> both languages, rebuilt every time `cache`
 *  is. A plain object rather than a Map because nothing here needs anything
 *  a Map offers and t() reads it far more often than this file writes it. */
let byKey: Record<string, { value_en: string; value_es: string }> = {}

function index(rows: ContentOverride[]) {
  byKey = Object.fromEntries(rows.map((r) => [r.key, { value_en: r.value_en, value_es: r.value_es }]))
}

async function fetchNow(): Promise<ContentOverride[]> {
  const { data, error } = await supabase.from('menu_content_overrides').select('*').order('key')
  if (error || !data) {
    console.warn('menu_content_overrides:', error?.message)
    return []
  }
  return data as ContentOverride[]
}

function fetchOverrides(): Promise<ContentOverride[]> {
  if (cache) return Promise.resolve(cache)
  if (!inflight) {
    inflight = fetchNow().then((rows) => {
      inflight = null
      cache = rows
      index(rows)
      listeners.forEach((l) => l(rows))
      return rows
    })
  }
  return inflight
}

async function refreshOverrides() {
  const rows = await fetchNow()
  cache = rows
  index(rows)
  listeners.forEach((l) => l(rows))
}

/** Exactly the pattern useMenuSections.clearMenuSections() sets: forget the
 *  cache so the next read is fresh. Not needed by AdminMenu itself (Realtime
 *  covers every write this screen makes to this table already), but kept
 *  for symmetry and for tests that might want to force a re-fetch. */
export function clearContentOverrides() {
  cache = null
  inflight = null
}

let realtimeStarted = false
function ensureRealtime() {
  if (realtimeStarted) return
  realtimeStarted = true
  supabase
    .channel('menu-content-overrides:live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'menu_content_overrides' },
        () => { void refreshOverrides() })
    .subscribe()
}

/** Synchronous read for translate(): whatever the cache holds right now, for
 *  this exact key and language. Undefined for a key nobody has overridden,
 *  or before the first fetch has landed -- both of which translate() treats
 *  as "fall back to the bundled dictionary", so a page that renders before
 *  this has fetched anything looks exactly like a database with no
 *  overrides in it, not like an error. */
export function getOverride(key: string, lang: Lang): string | undefined {
  const row = byKey[key]
  if (!row) return undefined
  return lang === 'es' ? row.value_es : row.value_en
}

/** i18n.ts calls this once, at module load, so its own `version` counter --
 *  and every useT() consumer subscribed to it -- bumps when an override
 *  arrives or changes, the same way it already does when a language
 *  dictionary finishes loading. */
export function subscribeOverrideChanges(fn: () => void): () => void {
  const l = () => fn()
  listeners.add(l)
  return () => listeners.delete(l)
}

/** The admin-facing hook: every override, for the "Content overrides" list
 *  in AdminMenu.tsx. Also the thing that actually starts the fetch and the
 *  Realtime subscription -- called from Lobby.tsx (see the effect there) so
 *  that by the time any screen renders a string through t(), the cache is
 *  either already warm or on its way. */
export function useContentOverrides(): ContentOverride[] {
  const [rows, setRows] = useState<ContentOverride[]>(cache ?? [])
  useEffect(() => {
    let alive = true
    ensureRealtime()
    void fetchOverrides().then((r) => { if (alive) setRows(r) })
    const l = (r: ContentOverride[]) => { if (alive) setRows(r) }
    listeners.add(l)
    return () => { alive = false; listeners.delete(l) }
  }, [])
  return rows
}

/** Start the fetch and the Realtime subscription without needing the list
 *  itself -- called once from Lobby.tsx, the same way primeLang() warms the
 *  language dictionary before anything on screen asks for it. */
export function primeContentOverrides() {
  ensureRealtime()
  void fetchOverrides()
}
