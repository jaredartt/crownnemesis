import { useEffect, useMemo, useRef, useState } from 'react'
import { TI } from '../lib/tablerIcons'
import { Ti } from './Ti'

/**
 * Pick one Tabler icon by looking at it. Used by the card admin for each
 * card's ability icon and for the three stat icons (movement, range, attack)
 * every card shares. The value is the icon's Tabler name ('apple', 'walk');
 * the card draws it white (filled where Tabler has a solid drawing).
 */
const NAMES = Object.keys(TI).sort()

export function IconPicker({ value, onChange, label }: {
  value: string | null | undefined
  onChange: (name: string) => void
  label?: string
}) {
  const [open, setOpen] = useState(false)
  const [q, setQ] = useState('')
  const box = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const away = (e: PointerEvent) => {
      if (!(e.target instanceof Node) || !box.current?.contains(e.target)) setOpen(false)
    }
    document.addEventListener('pointerdown', away, true)
    return () => document.removeEventListener('pointerdown', away, true)
  }, [open])

  const shown = useMemo(() => {
    const s = q.trim().toLowerCase()
    return s ? NAMES.filter((n) => n.includes(s)) : NAMES
  }, [q])

  return (
    <div className="iconpick" ref={box}>
      <button type="button" className="iconpick-btn" onClick={() => setOpen((o) => !o)} aria-label={label}>
        <span className="iconpick-cur">{value && TI[value] ? <Ti name={value} filled /> : null}</span>
        <span>{value || 'choose…'}</span>
      </button>
      {open && (
        <div className="iconpick-pop">
          <input
            autoFocus placeholder="Search icons (sword, heart, leaf…)" value={q}
            onChange={(e) => setQ(e.target.value)}
          />
          <div className="iconpick-grid">
            {shown.map((n) => (
              <button
                key={n} type="button" title={n}
                className={n === value ? 'is-on' : ''}
                onClick={() => { onChange(n); setOpen(false); setQ('') }}
              >
                <Ti name={n} filled />
              </button>
            ))}
            {shown.length === 0 && <p className="muted tiny">No icon by that name.</p>}
          </div>
        </div>
      )}
    </div>
  )
}
