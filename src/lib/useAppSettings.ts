/**
 * The `app_settings` singleton -- one row, `id = true`, game-wide rule
 * toggles. Today that is exactly one flag (see AppSettings in types.ts):
 * `friend_and_tournament_lp_enabled`, added by
 * 0066_temp_lp_from_friends_and_tournaments.sql.
 *
 * Same cache/listener/realtime shape as useMusic.ts's settings half --
 * copied rather than shared, for the same reason that file gives: a small
 * settings singleton is easier read in place than abstracted into
 * something generic enough for every table that ever wants this shape.
 */
import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { AppSettings } from './types'

const DEFAULT_APP_SETTINGS: AppSettings = { friend_and_tournament_lp_enabled: false }
let settingsCache: AppSettings | null = null
const settingsListeners = new Set<(s: AppSettings) => void>()

async function refreshAppSettings() {
  const { data, error } = await supabase
    .from('app_settings').select('friend_and_tournament_lp_enabled').eq('id', true).maybeSingle()
  const row = (!error && data ? data : DEFAULT_APP_SETTINGS) as AppSettings
  settingsCache = row
  settingsListeners.forEach((l) => l(row))
}

let realtimeStarted = false
function ensureRealtime() {
  if (realtimeStarted) return
  realtimeStarted = true
  supabase
    .channel('app_settings:live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'app_settings' },
        () => { void refreshAppSettings() })
    .subscribe()
}

export function useAppSettings(): AppSettings {
  const [s, setS] = useState<AppSettings>(settingsCache ?? DEFAULT_APP_SETTINGS)
  useEffect(() => {
    let alive = true
    ensureRealtime()
    if (!settingsCache) void refreshAppSettings()
    const l = (v: AppSettings) => { if (alive) setS(v) }
    settingsListeners.add(l)
    return () => { alive = false; settingsListeners.delete(l) }
  }, [])
  return s
}

/** The one write this settings row supports from the client: flipping the
 *  toggle. RLS (0066) holds this to cn_is_super_admin() regardless of what
 *  calls it -- AdminLadder.tsx is simply the only caller today. */
export async function setFriendTournamentLpEnabled(v: boolean): Promise<void> {
  const { error } = await supabase
    .from('app_settings').update({ friend_and_tournament_lp_enabled: v }).eq('id', true)
  if (error) throw error
}
