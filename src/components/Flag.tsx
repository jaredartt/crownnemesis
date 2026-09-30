import { useState } from 'react'
import { WORLD, WORLD_EMOJI, countryName } from '../lib/countries'
import { useT } from '../lib/i18n'

/**
 * A country's flag as a small, clean rectangle, or the globe for "World".
 *
 * Jared: "search for an API or something to get rectangular simple and clean
 * flags." These are the flag-icons set (MIT, github.com/lipis/flag-icons): the
 * 4x3 SVGs, one per ISO code, all the same proportions, served by jsDelivr --
 * no key, no account, cached hard. Emoji flags (the old way) looked different
 * on every OS and did not exist at all on Windows. If an image ever fails to
 * load, the two-letter code shows in a small badge instead, so a flag is never
 * just a hole.
 *
 * Renders nothing for no country, so callers can drop it in unconditionally.
 */
const FLAGS_BASE = 'https://cdn.jsdelivr.net/gh/lipis/flag-icons@7.2.3/flags/4x3/'

export function Flag({ code, className = '' }: { code?: string | null; className?: string }) {
  const t = useT()
  const [failed, setFailed] = useState(false)
  if (!code) return null
  const isWorld = code === WORLD
  const label = isWorld ? t('ladder.world') : countryName(code)
  if (isWorld) {
    return (
      <span className={`flag ${className}`} role="img" aria-label={label} title={label}>{WORLD_EMOJI}</span>
    )
  }
  if (failed || !/^[A-Za-z]{2}$/.test(code)) {
    return (
      <span className={`flag flag-code ${className}`} role="img" aria-label={label} title={label}>{code}</span>
    )
  }
  return (
    <span className={`flag flag-rect ${className}`} role="img" aria-label={label} title={label}>
      <img src={`${FLAGS_BASE}${code.toLowerCase()}.svg`} alt="" loading="lazy" decoding="async" onError={() => setFailed(true)} />
    </span>
  )
}
