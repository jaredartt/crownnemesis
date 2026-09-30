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

/** Jared: "all usernames, everywhere, they need to be Unbounded font, even in
 *  ladder, everywhere!" Every place that shows a player's name already runs it
 *  through nameColorStyle, so the typeface rides along with the colour: one
 *  door, no name left in the body font. (Only the Black weight of Unbounded is
 *  loaded, so the weight is pinned rather than left to a faux-bold guess.) */
export const NAME_FONT: CSSProperties = { fontFamily: 'var(--display)', fontWeight: 900 }

/** A `style` prop for a player's name: always the display face, plus the
 *  colour when there is one.
 *  0188: name colours are skins now -- the catalog (lib/progression.ts) is
 *  consulted first, so an admin-made gradient or shimmer renders everywhere a
 *  name does; until it has loaded, the nine originals still resolve from the
 *  theme variables above, and an unknown value falls back to whatever colour
 *  the element already had. */
export function nameColorStyle(color?: string | null): CSSProperties {
  if (!color) return NAME_FONT
  const skin = getSkin('name_color', color)
  if (skin) return { ...NAME_FONT, ...nameSkinStyle(skin) }
  return (NAME_COLORS as readonly string[]).includes(color) ? { ...NAME_FONT, color: `var(--nc-${color})` } : NAME_FONT
}
