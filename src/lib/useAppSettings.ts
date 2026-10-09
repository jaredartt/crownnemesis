/**
 * The `app_settings` singleton -- one row, `id = true`, game-wide rule
 * toggles and tunables (see AppSettings in types.ts):
 * `friend_and_tournament_lp_enabled` (0066), the ranked Elo K-factor
 * knobs `elo_k_placement`/`elo_k_established`/`elo_placement_games` (0082),
 * and `ranked_bot_after_seconds` (bot_identity_and_ranked_fallback).
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
  ranked_bot_after_seconds: 60,
  poison_pct: 10,
  burn_pct: 15,
  burn_on_attack: true,
  burn_on_ability: true,
  burn_on_move: false,
  burn_on_defend: false,
  burn_on_pass: false,
  stun_blocks_attack: true,
  stun_blocks_ability: true,
  stun_blocks_move: true,
  stun_blocks_defend: true,
  stat_icon_mov: 'walk',
  stat_icon_rng: 'target',
  stat_icon_atk: 'sword',
}
let settingsCache: AppSettings | null = null
const settingsListeners = new Set<(s: AppSettings) => void>()

async function refreshAppSettings() {
  const { data, error } = await supabase
    .from('app_settings')
    .select('friend_and_tournament_lp_enabled, elo_k_placement, elo_k_established, elo_placement_games, ranked_bot_after_seconds, poison_pct, burn_pct, burn_on_attack, burn_on_ability, burn_on_move, burn_on_defend, burn_on_pass, stun_blocks_attack, stun_blocks_ability, stun_blocks_move, stun_blocks_defend, stat_icon_mov, stat_icon_rng, stat_icon_atk')
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

/** How long ranked_tick() lets a player wait for a real opponent before
 *  falling back to a bot. Jared: "make it so that I can adjust how many
 *  seconds a player needs to wait without not finding a real player so that
 *  they fight a bot, give me the control from the admin page." Same
 *  singleton-row update, same RLS, same live-no-redeploy shape as
 *  setEloSettings above -- ranked_tick() reads this row fresh every call. */
export async function setRankedBotAfterSeconds(n: number): Promise<void> {
  const { error } = await supabase
    .from('app_settings').update({ ranked_bot_after_seconds: n }).eq('id', true)
  if (error) throw error
}

/** Poison and burn's own damage, each a percentage of the afflicted unit's
 *  own max HP -- cn_poison_pct()/cn_burn_pct() read this same row fresh
 *  every time they're called (a poison tick, an attack, an ability cast),
 *  so a change here takes effect on the very next one, no redeploy. Same
 *  RLS, same direct-update shape as every setter above. 1-100, same check
 *  constraint as the columns. */
export async function setEffectPcts(v: { poison_pct: number; burn_pct: number }): Promise<void> {
  const { error } = await supabase.from('app_settings').update(v).eq('id', true)
  if (error) throw error
}

/** 0157: the nine burn/stun toggles behind AdminEffects.tsx's two
 *  checklists -- see the AppSettings doc comment in types.ts for what each
 *  one actually does. Partial like setEloSettings's shape but built for a
 *  single checkbox flip at a time: AdminEffects.tsx calls this with one key
 *  set on every click rather than batching all nine behind one Save, so a
 *  toggle takes effect the moment it's clicked -- same RLS, same
 *  direct-update shape as every setter above. */
export async function setEffectToggles(v: Partial<{
  burn_on_attack: boolean
  burn_on_ability: boolean
  burn_on_move: boolean
  burn_on_defend: boolean
  burn_on_pass: boolean
  stun_blocks_attack: boolean
  stun_blocks_ability: boolean
  stun_blocks_move: boolean
  stun_blocks_defend: boolean
}>): Promise<void> {
  const { error } = await supabase.from('app_settings').update(v).eq('id', true)
  if (error) throw error
}

/** 0211: the three white icons on every card's Movement / Range / Attack
 *  rhomboids. One per stat for the whole game, so it is a settings write, not a
 *  card edit. RLS holds this to the super admin like every setter above. */
export async function setStatIcons(v: Partial<{
  stat_icon_mov: string
  stat_icon_rng: string
  stat_icon_atk: string
}>): Promise<void> {
  const { error } = await supabase.from('app_settings').update(v).eq('id', true)
  if (error) throw error
}
