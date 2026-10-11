import { useEffect, useRef, useState } from 'react'
import type { Card } from '../lib/types'
import { useAppSettings } from '../lib/useAppSettings'
import { cardValue, statusTone, valueLines, valueStatus } from '../lib/cardValue'

/** A number that rolls up (it went up) or down (it went down) when it changes. */
export function RollingNumber({ value, showDelta }: { value: number; showDelta?: boolean }) {
  const prev = useRef(value)
  const [anim, setAnim] = useState<{ from: number; to: number; dir: 'up' | 'down'; k: number } | null>(null)
  useEffect(() => {
    if (prev.current === value) return
    const a = { from: prev.current, to: value, dir: (value > prev.current ? 'up' : 'down') as 'up' | 'down', k: Math.random() }
    prev.current = value
    setAnim(a)
    const id = setTimeout(() => setAnim((x) => (x && x.k === a.k ? null : x)), 1150)
    return () => clearTimeout(id)
  }, [value])
  const fmt = (n: number) => (Number.isInteger(n) ? String(n) : n.toFixed(2).replace(/0+$/, ''))
  return (
    <>
      <span className="roll" aria-label={fmt(value)}>
        <span className="roll-size">{fmt(value)}</span>
        {anim
          ? <>
              <span key={`o${anim.k}`} className={`roll-old is-${anim.dir}`}>{fmt(anim.from)}</span>
              <span key={`n${anim.k}`} className={`roll-new is-${anim.dir}`}>{fmt(anim.to)}</span>
            </>
          : <span className="roll-new">{fmt(value)}</span>}
      </span>
      {showDelta && anim && (
        <span key={`d${anim.k}`} className={`roll-delta is-${anim.dir}`}>
          {anim.to - anim.from > 0 ? '+' : ''}{fmt(Math.round((anim.to - anim.from) * 100) / 100)}
        </span>
      )}
    </>
  )
}

/** The value of the card being built: the big number (green / yellow / red against the
 *  band set in Admin -> Card value), what it is made of, and the band itself. */
export function CardValueMeter({ card }: { card: Card }) {
  const s = useAppSettings()
  const v = cardValue(card, s)
  const st = valueStatus(v, s)
  const tone = statusTone(st)
  const lines = valueLines(card, s)
  const say = st === 'low' ? 'Too weak: below the minimum'
    : st === 'high' ? 'Too strong: above the maximum'
    : st === 'near-low' ? 'Close to the minimum'
    : st === 'near-high' ? 'Close to the maximum'
    : 'Within the band'
  return (
    <div className={`cardvalue is-${tone}`}>
      <p className="cardvalue-label">Card value</p>
      <div className="cardvalue-num">
        <RollingNumber key={card.id} value={v} showDelta />  {/* keyed by card: switching cards remounts it, so only an edit rolls */}
        <span className="cardvalue-unit">VP</span>
      </div>
      <p className="cardvalue-state">{say}</p>
      <p className="cardvalue-band">Band: {s.vp_min ?? 0} to {s.vp_max ?? 0} VP (close = within {s.vp_warn ?? 0})</p>
      <table className="cardvalue-bill">
        <tbody>
          {lines.map((l) => (
            <tr key={l.label}>
              <td>{l.label}</td>
              <td className="muted">{l.label.startsWith('Class') ? '' : `${l.amount} × ${l.each}`}</td>
              <td>{Math.round(l.total * 100) / 100}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
