import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { useMusicSettings, useMusicTracks } from '../lib/useMusic'
import type { MusicTrack } from '../lib/types'

/**
 * Sound & Music Manager, the playlist half. The card-by-card half -- attack,
 * ability, passive, walking -- lives inside the card editor itself, in
 * AdminCards.tsx's AudioFields; see that file's own comment for why. This is
 * the other kind of sound in the game: not tied to a card, tied to a SCREEN
 * -- the lobby, or a match -- and there are exactly two of those.
 *
 * Every write here is an ordinary table write, held to cn_is_super_admin()
 * by the RLS policies in 0041_music.sql -- there is nothing to wrap them in,
 * the same way AdminCards has nothing to wrap a card save in beyond the
 * policy that already guards `cards`.
 */
function Playlist({ category, label }: { category: 'menu' | 'battle'; label: string }) {
  const allTracks = useMusicTracks()
  const settings = useMusicSettings()
  const tracks = allTracks
    .filter((t) => t.category === category)
    .slice()
    .sort((a, b) => a.sort - b.sort)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  async function upload(file: File) {
    setBusy(true); setErr(null)
    const path = `music/${category}/${Date.now().toString(36)}-${file.name}`
    const { error: upErr } = await supabase.storage.from('audio')
      .upload(path, file, { contentType: file.type || undefined })
    if (upErr) { setBusy(false); setErr(upErr.message); return }
    const { data } = supabase.storage.from('audio').getPublicUrl(path)
    const nextSort = tracks.length ? Math.max(...tracks.map((t) => t.sort)) + 1 : 0
    const { error } = await supabase.from('music_tracks').insert({
      category, title: file.name.replace(/\.[a-z0-9]+$/i, ''), url: data.publicUrl, sort: nextSort,
    })
    setBusy(false)
    if (error) setErr(error.message)
  }

  async function toggleActive(t: MusicTrack) {
    setErr(null)
    const { error } = await supabase.from('music_tracks').update({ is_active: !t.is_active }).eq('id', t.id)
    if (error) setErr(error.message)
  }

  async function remove(t: MusicTrack) {
    setErr(null)
    const { error } = await supabase.from('music_tracks').delete().eq('id', t.id)
    if (error) setErr(error.message)
  }

  // Swaps the two rows' `sort` values rather than renumbering the whole
  // list -- one up/down click is two small writes instead of N, and two
  // admins nudging different tracks at once do not stomp on a list they are
  // not touching.
  async function move(t: MusicTrack, dir: -1 | 1) {
    const idx = tracks.findIndex((x) => x.id === t.id)
    const swap = tracks[idx + dir]
    if (!swap) return
    setBusy(true); setErr(null)
    const { error: e1 } = await supabase.from('music_tracks').update({ sort: swap.sort }).eq('id', t.id)
    const { error: e2 } = await supabase.from('music_tracks').update({ sort: t.sort }).eq('id', swap.id)
    setBusy(false)
    if (e1 || e2) setErr((e1 ?? e2)?.message ?? 'could not reorder')
  }

  async function setShuffle(v: boolean) {
    setErr(null)
    const column = category === 'menu' ? 'menu_shuffle' : 'battle_shuffle'
    const { error } = await supabase.from('music_settings').update({ [column]: v }).eq('id', true)
    if (error) setErr(error.message)
  }

  const shuffle = category === 'menu' ? settings.menu_shuffle : settings.battle_shuffle

  return (
    <div className="admin-playlist">
      <div className="admin-playlist-head">
        <h3>{label}</h3>
        <label className="admin-flag">
          <input type="checkbox" checked={shuffle} onChange={(e) => void setShuffle(e.target.checked)} />
          <span>Shuffle</span>
        </label>
      </div>
      <ul className="admin-tracklist">
        {tracks.map((t, i) => (
          <li key={t.id} className={t.is_active ? '' : 'is-retired'}>
            <span className="admin-trackname">{t.title || t.url}</span>
            <span className="admin-trackacts">
              <button
                type="button" className="btn tiny ghost" disabled={busy || i === 0}
                onClick={() => void move(t, -1)} aria-label="Move earlier"
              >
                ↑
              </button>
              <button
                type="button" className="btn tiny ghost" disabled={busy || i === tracks.length - 1}
                onClick={() => void move(t, 1)} aria-label="Move later"
              >
                ↓
              </button>
              <button type="button" className="btn tiny ghost" onClick={() => void toggleActive(t)}>
                {t.is_active ? 'Disable' : 'Enable'}
              </button>
              <button type="button" className="btn tiny ghost" onClick={() => void remove(t)}>
                Remove
              </button>
            </span>
          </li>
        ))}
        {tracks.length === 0 && <li className="muted tiny">No tracks yet.</li>}
      </ul>
      <label className="admin-upload">
        <span>{busy ? 'Uploading…' : `Add a ${label.toLowerCase()} track (.wav or .mp3)`}</span>
        <input
          type="file" accept="audio/*" disabled={busy}
          onChange={(e) => { const f = e.target.files?.[0]; if (f) void upload(f) }}
        />
      </label>
      {err && <p className="error tiny">{err}</p>}
    </div>
  )
}

export function AdminMusic() {
  return (
    <div className="admin-music">
      <Playlist category="menu" label="Menu music" />
      <Playlist category="battle" label="Battle music" />
    </div>
  )
}
