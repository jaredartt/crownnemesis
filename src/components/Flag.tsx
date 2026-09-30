import { WORLD, WORLD_EMOJI, countryName, flagEmoji, supportsFlagEmoji } from '../lib/countries'
import { useT } from '../lib/i18n'

/**
 * A country's flag, or the globe for "World".
 *
 * Renders nothing for no country, so callers can drop it in unconditionally.
 * On a device with no flag emojis (Windows) it shows the two-letter code in a
 * small badge instead -- see supportsFlagEmoji in lib/countries.ts.
 */
export function Flag({ code, className = '' }: { code?: string | null; className?: string }) {
  const t = useT()
  if (!code) return null
  const isWorld = code === WORLD
  const label = isWorld ? t('ladder.world') : countryName(code)
  if (isWorld || supportsFlagEmoji()) {
    return (
      <span className={`flag ${className}`} role="img" aria-label={label} title={label}>
        {isWorld ? WORLD_EMOJI : flagEmoji(code)}
      </span>
    )
  }
  return (
    <span className={`flag flag-code ${className}`} role="img" aria-label={label} title={label}>
      {code}
    </span>
  )
}
