import { useEffect, useRef, useState } from 'react'
import { setLookFeel, useAppSettings } from '../lib/useAppSettings'
import { StatIconsPanel, HoverCardSizePanel } from './AdminCardPanels'
import { applyLookFeel, LOOK_DEFAULTS, type LookFeel } from '../lib/lookFeel'

/**
 * Admin Mode -> Look & feel (0220). Five dials for how the game feels, each a
 * percentage of the default (100 = as it was). Moving a slider previews it on
 * this screen straight away (the menu animations and the bar below respond);
 * Save makes it the look for everybody. Leaving the tab without saving puts your
 * own screen back. The stat icons on every card and the hovered card's size are at the bottom.
 *
 * Where each one is applied: lib/lookFeel.ts.
 */
type Key = keyof LookFeel
const DIALS: { key: Key; label: string; min: number; max: number; step: number; note: string }[] = [
  { key: 'fight_speed', label: 'Fight scenes', min: 50, max: 200, step: 5,
    note: 'How fast the face-off plays. 200% is twice as fast, 50% half speed. Try it in the Playtest tab.' },
  { key: 'ui_speed', label: 'Menu and transitions', min: 50, max: 200, step: 5,
    note: 'Tiles sliding in, the sweep between menu and match, the action menu popping up.' },
  { key: 'hp_drain_speed', label: 'HP bar animation', min: 50, max: 200, step: 5,
    note: 'How quickly the white ghost drains, the bar slides, and the HP number counts.' },
  { key: 'hp_bar_thickness', label: 'HP bar thickness', min: 60, max: 160, step: 5,
    note: 'On board tokens and in fight scenes. The number grows with the bar.' },
  { key: 'motion_blur', label: 'Motion blur', min: 0, max: 200, step: 10,
    note: '0% is off, 100% is the standard amount. Blurs units as they slide and lunge, armies and structures as they land, menu tiles flying in, fight-scene entrances and the hover card. Players with Reduce motion on never see it.' },
]

export function AdminLook() {
  const s = useAppSettings()
  const saved: LookFeel = {
    fight_speed: s.fight_speed ?? 100, ui_speed: s.ui_speed ?? 100,
    hp_drain_speed: s.hp_drain_speed ?? 100, hp_bar_thickness: s.hp_bar_thickness ?? 100,
    motion_blur: s.motion_blur ?? 100,
  }
  const [draft, setDraft] = useState<LookFeel>(saved)
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [savedNote, setSavedNote] = useState(false)
  const savedRef = useRef(saved)
  savedRef.current = saved

  useEffect(() => { if (!dirty) setDraft(saved) }, [s.fight_speed, s.ui_speed, s.hp_drain_speed, s.hp_bar_thickness, s.motion_blur, dirty]) // eslint-disable-line react-hooks/exhaustive-deps
  // Put this screen back to what is saved when the tab is left.
  useEffect(() => () => applyLookFeel(savedRef.current), [])

  const set = (k: Key, v: number) => {
    const next = { ...draft, [k]: v }
    setDraft(next); setDirty(true); setSavedNote(false)
    applyLookFeel(next)
  }

  async function save() {
    setBusy(true); setErr(null)
    try {
      await setLookFeel(draft)
      setDirty(false); setSavedNote(true)
    } catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  return (
    <div className="admin-look">
      <h2>Look &amp; feel</h2>
      <p className="muted tiny">
        Percentages of the default look. Move a slider to preview it here; Save to change it for everybody.
      </p>
      <div className="look-list">
        {DIALS.map((d) => (
          <label key={d.key} className="look-row">
            <span className="look-name">{d.label}</span>
            <output className="look-val">{draft[d.key]}%</output>
            <input
              type="range" min={d.min} max={d.max} step={d.step} value={draft[d.key]}
              onChange={(e) => set(d.key, Number(e.target.value))}
            />
            <span className="look-note muted tiny">{d.note}</span>
          </label>
        ))}
      </div>

      <div className="look-demo" aria-hidden="true">
        <div className="look-demo-bar"><i style={{ width: '62%' }} /></div>
        <span className="muted tiny">The bar above is a preview of the thickness.</span>
      </div>
      <div className="look-mb-demo" aria-hidden="true"><i /></div>
      <p className="muted tiny" style={{ margin: '0 0 14px' }}>The square is a preview of the motion blur (it is off if your own Reduce motion is on).</p>

      <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
        <button className="btn primary" disabled={busy || !dirty} onClick={() => void save()}>
          {busy ? 'Saving…' : 'Save look'}
        </button>
        <button
          className="btn ghost" disabled={busy}
          onClick={() => { setDraft(LOOK_DEFAULTS); setDirty(true); setSavedNote(false); applyLookFeel(LOOK_DEFAULTS) }}
        >
          Back to defaults
        </button>
        {savedNote && <span className="muted tiny">Saved. Live for everybody.</span>}
      </div>
      {err && <p className="error tiny">{err}</p>}

      <StatIconsPanel />
      <HoverCardSizePanel />
    </div>
  )
}
