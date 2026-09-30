import type { CSSProperties } from 'react'
import { getSkin } from './progression'
import { nameSkinStyle } from './skinStyle'

/**
 * 0060: the nine name colors a player can pick in Profile. Kept as CSS
 * custom properties (`--nc-*`, defined in styles.css) rather than plain hex
 * here, so `black`/`gray` can quietly BE the theme's own `--ink`/`--muted`
 * -- legible in light and dark mode for free, with no separate dark-theme
 * override to maintain.
 */
export const NAME_COLORS = [
  'red', 'orange', 'green', 'sky', 'blue', 'purple', 'black', 'gray', 'brown',
] as const

export type NameColor = typeof NAME_COLORS[number]

/** A `style` prop for coloring a name, or undefined for "leave it alone".
 *  0188: name colours are skins now -- the catalog (lib/progression.ts) is
 *  consulted first, so an admin-made gradient or shimmer renders everywhere a
 *  name does; until it has loaded, the nine originals still resolve from the
 *  theme variables above, and an unknown value falls back to whatever colour
 *  the element already had. */
export function nameColorStyle(color?: string | null): CSSProperties | undefined {
  if (!color) return undefined
  const skin = getSkin('name_color', color)
  if (skin) return nameSkinStyle(skin)
  return (NAME_COLORS as readonly string[]).includes(color) ? { color: `var(--nc-${color})` } : undefined
}
