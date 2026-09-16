import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { useMenuSections } from '../lib/useMenuSections'

/** English labels for the lobby's own tile ids -- see TILES in Lobby.tsx.
 *  Not read from the dictionary: this screen is Admin Mode, and Admin Mode
 *  does not go through t() any more than AdminCards does. */
const TILE_LABELS: Record<string, string> = {
  ranked: 'Ranked', bot: 'Practice', friends: 'Friends', spectate: 'Watch',
  ladder: 'Ladder', team: 'My Kingdom', tournament: 'Tournament', comics: 'Comics',
}

/**
 * Live Menu Manager. Every row here is a `menu_sections` row (0042); Lobby.tsx
 * folds visible/sort over its own TILES constant, which is where the colour,
 * the picture and the focus point still live -- this screen only ever
 * decides whether a tile is shown and where it sits, never what it looks
 * like.
 */
export function AdminMenu() {
  const sections = useMenuSections()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  const ordered = sections.slice().sort((a, b) => a.sort - b.sort)

  async function toggleVisible(id: string, visible: boolean) {
    setErr(null)
    const { error } = await supabase.from('menu_sections').update({ visible }).eq('id', id)
    if (error) setErr(error.message)
  }

  async function move(id: string, dir: -1 | 1) {
    const idx = ordered.findIndex((s) => s.id === id)
    const a = ordered[idx]
    const swap = ordered[idx + dir]
    if (!a || !swap) return
    setBusy(true); setErr(null)
    const { error: e1 } = await supabase.from('menu_sections').update({ sort: swap.sort }).eq('id', a.id)
    const { error: e2 } = await supabase.from('menu_sections').update({ sort: a.sort }).eq('id', swap.id)
    setBusy(false)
    if (e1 || e2) setErr((e1 ?? e2)?.message ?? 'could not reorder')
  }

  return (
    <div className="admin-menu">
      <p className="muted tiny admin-wide">
        Show, hide or reorder the lobby's tiles. Every signed-in player sees the
        change within a moment of it landing here -- no deploy, no refresh.
      </p>
      <ul className="admin-sectionlist">
        {ordered.map((s, i) => (
          <li key={s.id} className={s.visible ? '' : 'is-retired'}>
            <span className="admin-rowname">{TILE_LABELS[s.id] ?? s.id}</span>
            <span className="admin-trackacts">
              <button
                type="button" className="btn tiny ghost" disabled={busy || i === 0}
                onClick={() => void move(s.id, -1)} aria-label="Move earlier"
              >
                ↑
              </button>
              <button
                type="button" className="btn tiny ghost" disabled={busy || i === ordered.length - 1}
                onClick={() => void move(s.id, 1)} aria-label="Move later"
              >
                ↓
              </button>
              <label className="admin-flag">
                <input
                  type="checkbox" checked={s.visible} disabled={busy}
                  onChange={(e) => void toggleVisible(s.id, e.target.checked)}
                />
                <span>Visible</span>
              </label>
            </span>
          </li>
        ))}
        {ordered.length === 0 && (
          <li className="muted tiny">
            Nothing here yet -- run 0042_menu_sections.sql in the Supabase SQL Editor.
          </li>
        )}
      </ul>
      {err && <p className="error tiny">{err}</p>}
    </div>
  )
}
