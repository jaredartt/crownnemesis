import { useMemo, useState } from 'react'
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
 * It opens IN the page rather than as a floating menu: it lives inside a
 * scrolling modal on the profile, where a popup would be clipped by the
 * modal's own overflow.
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
        type="button" className="cpick-btn" disabled={disabled}
        aria-expanded={open} aria-haspopup="listbox"
        onClick={() => setOpen((o) => !o)}
      >
        {value ? <Flag code={value} /> : <span className="cpick-noflag" aria-hidden="true">–</span>}
        <span className="cpick-name">{label}</span>
        <span className="cpick-caret" aria-hidden="true">{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div className="cpick-panel">
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
        </div>
      )}
    </div>
  )
}
