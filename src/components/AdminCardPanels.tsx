import { useEffect, useState } from 'react'
import { IconPicker } from './IconPicker'
import { useAppSettings, setStatIcons, setHoverCardSize } from '../lib/useAppSettings'

/** 0211: the three white icons on every card's Movement (blue), Range (green)
 *  and Attack (red) rhomboids. Global, so it lives beside the card form rather
 *  than inside one card; each pick saves at once, like AdminEffects' toggles. */
export function StatIconsPanel() {
  const cfg = useAppSettings()
  const [err, setErr] = useState<string | null>(null)
  const pick = (v: Parameters<typeof setStatIcons>[0]) => {
    setErr(null)
    setStatIcons(v).catch((e: { message?: string }) => setErr(e.message ?? 'Could not save'))
  }
  return (
    <details className="admin-wide admin-staticons">
      <summary>Stat icons on every card</summary>
      <div className="admin-grid">
        <label><span>Movement (blue)</span>
          <IconPicker value={cfg.stat_icon_mov} label="Movement icon" onChange={(n) => pick({ stat_icon_mov: n })} />
        </label>
        <label><span>Range (green)</span>
          <IconPicker value={cfg.stat_icon_rng} label="Range icon" onChange={(n) => pick({ stat_icon_rng: n })} />
        </label>
        <label><span>Attack (red)</span>
          <IconPicker value={cfg.stat_icon_atk} label="Attack icon" onChange={(n) => pick({ stat_icon_atk: n })} />
        </label>
      </div>
      <p className="muted tiny">Saved the moment you pick one; every card changes with it.</p>
      {err && <p className="error">{err}</p>}
    </details>
  )
}


/** 0214: how big the hovered / pinned card is on desktop. Two numbers, saved the
 *  moment you let go of a slider; every card open on any screen resizes with it. */
export function HoverCardSizePanel() {
  const cfg = useAppSettings()
  const [vh, setVh] = useState<number>(cfg.hover_card_vh ?? 36)
  const [max, setMax] = useState<number>(cfg.hover_card_max ?? 390)
  const [err, setErr] = useState<string | null>(null)
  // Follow the saved value when it arrives (first load, or another admin tab).
  useEffect(() => { setVh(cfg.hover_card_vh ?? 36); setMax(cfg.hover_card_max ?? 390) }, [cfg.hover_card_vh, cfg.hover_card_max])
  const save = (v: Parameters<typeof setHoverCardSize>[0]) => {
    setErr(null)
    setHoverCardSize(v).catch((e: { message?: string }) => setErr(e.message ?? 'Could not save'))
  }
  return (
    <details className="admin-wide admin-hovercard">
      <summary>Hover card size (desktop)</summary>
      <div className="admin-grid">
        <label><span>Width: {vh}% of the window height</span>
          <input type="range" min={15} max={70} step={1} value={vh}
            onChange={(e) => setVh(Number(e.target.value))}
            onPointerUp={() => save({ hover_card_vh: vh })}
            onKeyUp={() => save({ hover_card_vh: vh })} />
        </label>
        <label><span>Never wider than {max}px</span>
          <input type="range" min={150} max={800} step={10} value={max}
            onChange={(e) => setMax(Number(e.target.value))}
            onPointerUp={() => save({ hover_card_max: max })}
            onKeyUp={() => save({ hover_card_max: max })} />
        </label>
      </div>
      <p className="muted tiny">Applies to the card that opens beside the board on desktop (it slides over the chat / battle log). Phones keep their own. Saved when you let go; open a card on the board to see it.</p>
      {err && <p className="error">{err}</p>}
    </details>
  )
}
