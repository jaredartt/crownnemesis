/**
 * Two playlists and the shared player behind settings.music.
 *
 * The cache/listener shape is useCards.ts's, copied rather than generalised
 * into something both files import -- two tiny copies of one pattern are
 * easier to read in place than a shared helper that has to be abstract
 * enough for a roster of cards AND a settings singleton AND a list of
 * tracks. See 0041_music.sql for the tables this reads.
 */
import { useEffect, useState } from 'react'
import { supabase } from './supabase'
import { useSettings } from './settings'
import type { MusicSettings, MusicTrack } from './types'

/* ---------------------------------------------------------------------------
 * Tracks
 * ------------------------------------------------------------------------- */
let trackCache: MusicTrack[] | null = null
let trackInflight: Promise<MusicTrack[]> | null = null
const trackListeners = new Set<(t: MusicTrack[]) => void>()

async function fetchTracksNow(): Promise<MusicTrack[]> {
  const { data, error } = await supabase
    .from('music_tracks').select('*').eq('is_active', true).order('sort')
  if (error || !data) {
    console.warn('music_tracks:', error?.message)
    return []
  }
  return data as MusicTrack[]
}

function fetchTracks(): Promise<MusicTrack[]> {
  if (trackCache) return Promise.resolve(trackCache)
  if (!trackInflight) {
    trackInflight = fetchTracksNow().then((rows) => {
      trackInflight = null
      trackCache = rows
      trackListeners.forEach((l) => l(rows))
      return rows
    })
  }
  return trackInflight
}

async function refreshTracks() {
  const rows = await fetchTracksNow()
  trackCache = rows
  trackListeners.forEach((l) => l(rows))
}

/* ---------------------------------------------------------------------------
 * The shuffle toggles -- one row, see 0041_music.sql
 * ------------------------------------------------------------------------- */
const DEFAULT_MUSIC_SETTINGS: MusicSettings = { menu_shuffle: true, battle_shuffle: true }
let settingsCache: MusicSettings | null = null
const settingsListeners = new Set<(s: MusicSettings) => void>()

async function refreshMusicSettings() {
  const { data, error } = await supabase
    .from('music_settings').select('menu_shuffle,battle_shuffle').eq('id', true).maybeSingle()
  const row = (!error && data ? data : DEFAULT_MUSIC_SETTINGS) as MusicSettings
  settingsCache = row
  settingsListeners.forEach((l) => l(row))
}

let realtimeStarted = false
function ensureRealtime() {
  if (realtimeStarted) return
  realtimeStarted = true
  supabase
    .channel('music:live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'music_tracks' },
        () => { void refreshTracks() })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'music_settings' },
        () => { void refreshMusicSettings() })
    .subscribe()
}

export function useMusicTracks(): MusicTrack[] {
  const [tracks, setTracks] = useState<MusicTrack[]>(trackCache ?? [])
  useEffect(() => {
    let alive = true
    ensureRealtime()
    void fetchTracks().then((t) => { if (alive) setTracks(t) })
    const l = (t: MusicTrack[]) => { if (alive) setTracks(t) }
    trackListeners.add(l)
    return () => { alive = false; trackListeners.delete(l) }
  }, [])
  return tracks
}

export function useMusicSettings(): MusicSettings {
  const [s, setS] = useState<MusicSettings>(settingsCache ?? DEFAULT_MUSIC_SETTINGS)
  useEffect(() => {
    let alive = true
    ensureRealtime()
    if (!settingsCache) void refreshMusicSettings()
    const l = (v: MusicSettings) => { if (alive) setS(v) }
    settingsListeners.add(l)
    return () => { alive = false; settingsListeners.delete(l) }
  }, [])
  return s
}

/* ---------------------------------------------------------------------------
 * The player itself.
 *
 * One shared HTMLAudioElement for the whole app rather than one per screen.
 * App.tsx is the only caller, and it is in exactly one of three states at a
 * time -- signed out, in the lobby, or in a match -- so there is never a
 * moment two categories both want to be playing, and reusing the element
 * across a lobby<->match crossing means the crossing does not cut a track
 * off mid-note the way tearing down and rebuilding an <audio> would.
 * ------------------------------------------------------------------------- */
let el: HTMLAudioElement | null = null
let queue: MusicTrack[] = []
let queueIdx = 0
let activeCategory: 'menu' | 'battle' | null = null

function shuffled<T>(a: T[]): T[] {
  const out = a.slice()
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[out[i], out[j]] = [out[j], out[i]]
  }
  return out
}

function ensureEl(): HTMLAudioElement {
  if (!el) {
    el = new Audio()
    el.addEventListener('ended', () => {
      if (!queue.length) return
      queueIdx = (queueIdx + 1) % queue.length
      playCurrent()
    })
  }
  return el
}

function playCurrent() {
  if (!queue.length) { el?.pause(); return }
  const track = queue[queueIdx % queue.length]
  const e = ensureEl()
  if (e.src !== track.url) e.src = track.url
  void e.play().catch(() => { /* needs a gesture first on some browsers */ })
}

/**
 * Point the shared player at a category, or at nothing (null: signed out, or
 * between screens). Rebuilds its queue whenever the track list or the
 * shuffle toggle changes for the category it is currently pointed at, but
 * keeps whatever is already playing when the currently-playing track is
 * still in the new list -- an admin adding a second battle track from the
 * Music tab should not cut off the first one that was already going.
 */
export function useMusicCategory(category: 'menu' | 'battle' | null) {
  const tracks = useMusicTracks()
  const settings = useMusicSettings()
  const { music } = useSettings()

  useEffect(() => {
    if (!category) {
      if (activeCategory !== null) {
        ensureEl().pause()
        activeCategory = null
        queue = []
        queueIdx = 0
      }
      return
    }
    const shuffle = category === 'menu' ? settings.menu_shuffle : settings.battle_shuffle
    const list = tracks.filter((t) => t.category === category).slice().sort((a, b) => a.sort - b.sort)
    const ordered = shuffle ? shuffled(list) : list
    const wasPlaying = queue[queueIdx]
    const stillCurrent = activeCategory === category
      && wasPlaying && ordered.some((t) => t.id === wasPlaying.id)

    queue = ordered
    if (stillCurrent) {
      queueIdx = queue.findIndex((t) => t.id === wasPlaying!.id)
    } else {
      queueIdx = 0
      activeCategory = category
      playCurrent()
    }
  }, [category, tracks, settings.menu_shuffle, settings.battle_shuffle])

  useEffect(() => {
    ensureEl().volume = Math.max(0, Math.min(1, music))
  }, [music])
}
