import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import { createPortal } from 'react-dom'
import { COUNTRY_CODES, WORLD, countryName } from '../lib/countries'
import { currentLang, useT } from '../lib/i18n'
import { Flag } from './Flag'

/**
 * Pick a country. One component for two jobs:
 *
 *   Profile  -- value is a code or null (no flag); `allowNone` adds a
 *               "No flag" row.
 *   Ladder   -- value is a code or WORLD; `allowWorld` adds the "World" row,
 *               and `counts` (how many players each country has) floats the
 *               countries that actually have someone on the ladder to the top.
 *
 * The list FLOATS over the page instead of opening in the flow (Jared: "when
 * opening drop-downs, it pushes everything underneath... make it go on top of
 * the content instead, with a subtle shadow"). It is portalled to <body> and
 * placed with `position: fixed` from the button's own rectangle, which is what
 * lets it work in both homes: on the ladder, and inside the profile modal,
 * whose `overflow` would clip (or stretch the scroll height of) an ordinary
 * absolutely-positioned child. It opens downward, or upward when there is more
 * room above the button, and follows the button if anything scrolls.
 */
export function CountryPicker({
  value, onChange, allowNone, allowWorld, counts, disabled,
}: {
  value: string | null
  onChange: (v: string | null) => void
  allowNone?: boolean
  allowWorld?: boolean
  counts?: Record<string, number>
  disabled?: boolean
}) {
  const t = useT()
  const lang = currentLang()
  const [open, setOpen] = useState(false)
  const [q, setQ] = useState('')
  const btn = useRef<HTMLButtonElement>(null)
  const panel = useRef<HTMLDivElement>(null)
  const [pos, setPos] = useState<CSSProperties | null>(null)

  const place = useCallback(() => {
    const b = btn.current
    if (!b) return
    const r = b.getBoundingClientRect()
    const vh = window.innerHeight
    const below = vh - r.bottom - 12
    const above = r.top - 12
    // A full panel is roughly 300px (search box + a 240px list). Prefer
    // below; go up only if that is cramped AND up has more room.
    const up = below < 300 && above > below
    const room = Math.max(160, up ? above : below)
    setPos({
      position: 'fixed', left: r.left, width: r.width,
      ...(up ? { bottom: vh - r.top + 6 } : { top: r.bottom + 6 }),
      maxHeight: room,
    })
  }, [])

  useLayoutEffect(() => { if (open) place() }, [open, place])
  useEffect(() => {
    if (!open) return
    const away = (e: PointerEvent) => {
      const n = e.target as Node
      if (panel.current?.contains(n) || btn.current?.contains(n)) return
      setOpen(false); setQ('')
    }
    // Escape closes just the list, not the modal/page behind it.
    const key = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.stopPropagation(); e.preventDefault()
      setOpen(false); setQ('')
      btn.current?.focus()
    }
    document.addEventListener('pointerdown', away, true)
    window.addEventListener('keydown', key, true)
    window.addEventListener('scroll', place, true)
    window.addEventListener('resize', place)
    return () => {
      document.removeEventListener('pointerdown', away, true)
      window.removeEventListener('keydown', key, true)
      window.removeEventListener('scroll', place, true)
      window.removeEventListener('resize', place)
    }
  }, [open, place])

  const all = useMemo(
    () => COUNTRY_CODES
      .map((code) => ({ code, name: countryName(code, lang) }))
      .sort((a, b) => a.name.localeCompare(b.name, lang)),
    [lang],
  )
  const needle = q.trim().toLowerCase()
  const matches = needle
    ? all.filter((c) => c.name.toLowerCase().includes(needle) || c.code.toLowerCase() === needle)
    : all
  const withPlayers = counts ? matches.filter((c) => (counts[c.code] ?? 0) > 0) : []
  withPlayers.sort((a, b) => (counts![b.code] - counts![a.code]) || a.name.localeCompare(b.name, lang))
  const rest = counts ? matches.filter((c) => !(counts[c.code] > 0)) : matches

  const label = value === WORLD ? t('ladder.world')
    : value ? countryName(value, lang)
    : t('profile.noFlag')

  function pick(v: string | null) {
    setOpen(false); setQ('')
    if (v !== value) onChange(v)
  }

  const row = (code: string | null, name: string, n?: number) => (
    <li key={code ?? 'none'}>
      <button
        type="button" role="option" aria-selected={code === value}
        className={`cpick-row${code === value ? ' is-on' : ''}`}
        onClick={() => pick(code)}
      >
        {code ? <Flag code={code} /> : <span className="flag" aria-hidden="true" />}
        <span className="cpick-name">{name}</span>
        {n != null && n > 0 && <span className="cpick-count">{n}</span>}
      </button>
    </li>
  )

  return (
    <div className="cpick">
      <button
        ref={btn} type="button" className="cpick-btn" disabled={disabled}
        aria-expanded={open} aria-haspopup="listbox"
        onClick={() => setOpen((o) => !o)}
      >
        {value ? <Flag code={value} /> : <span className="cpick-noflag" aria-hidden="true">–</span>}
        <span className="cpick-name">{label}</span>
        <span className="cpick-caret" aria-hidden="true">{open ? '▲' : '▼'}</span>
      </button>
      {open && pos && createPortal(
        <div className="cpick-panel" ref={panel} style={pos}>
          <input
            className="cpick-search" value={q} autoFocus autoComplete="off"
            placeholder={t('profile.searchCountry')}
            onChange={(e) => setQ(e.target.value)}
          />
          <ul className="cpick-list" role="listbox">
            {allowWorld && !needle && row(WORLD, t('ladder.world'), counts ? Object.values(counts).reduce((a, b) => a + b, 0) : undefined)}
            {allowNone && !needle && row(null, t('profile.noFlag'))}
            {withPlayers.length > 0 && <li className="cpick-head">{t('ladder.countriesWithPlayers')}</li>}
            {withPlayers.map((c) => row(c.code, c.name, counts![c.code]))}
            {withPlayers.length > 0 && rest.length > 0 && <li className="cpick-head">{t('ladder.allCountries')}</li>}
            {rest.map((c) => row(c.code, c.name))}
            {matches.length === 0 && <li className="cpick-head">{t('profile.noCountryFound')}</li>}
          </ul>
        </div>,
        document.body,
      )}
    </div>
  )
}
