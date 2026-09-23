/**
 * The `app_settings` singleton -- one row, `id = true`, game-wide rule
 * toggles and tunables (see AppSettings in types.ts):
 * `friend_and_tournament_lp_enabled` (0066), and the ranked Elo K-factor
 * knobs `elo_k_placement`/`elo_k_established`/`elo_placement_games` (0082).
 *
 * Same cache/listener/realtime shape as useMusic.ts's settings half --
 * copied rather than shared, for the same reason that file gives: a small
 * settings singleton is easier read in place than abstracted into
 * something generic enough for every table that ever wants this shape.
 */
import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import type { AppSettings } from './types'

const DEFAULT_APP_SETTINGS: AppSettings = {
  friend_and_tournament_lp_enabled: false,
  elo_k_placement: 40,
  elo_k_established: 20,
  elo_placement_games: 10,
}
let settingsCache: AppSettings | null = null
const settingsListeners = new Set<(s: AppSettings) => void>()

async function refreshAppSettings() {
  const { data, error } = await supabase
    .from('app_settings')
    .select('friend_and_tournament_lp_enabled, elo_k_placement, elo_k_established, elo_placement_games')
    .eq('id', true).maybeSingle()
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

/** The Elo K-factor knobs -- 0082_raw_rating_system.sql's cn_elo_k() reads
 *  this same row at the moment every ranked match finishes, so a change
 *  here takes effect immediately, no redeploy, exactly like the toggle
 *  above. Same RLS ("super admin writes app settings"), same direct-update
 *  shape -- there is no dedicated RPC for this any more than there is for
 *  the toggle. */
export async function setEloSettings(v: {
  elo_k_placement: number
  elo_k_established: number
  elo_placement_games: number
}): Promise<void> {
  const { error } = await supabase.from('app_settings').update(v).eq('id', true)
  if (error) throw error
}
