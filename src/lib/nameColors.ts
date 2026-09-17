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

/** A `style` prop for coloring a name, or undefined for "leave it alone" --
 *  an unset/unrecognized value (an older cached row, a future color this
 *  build doesn't know yet) falls back to whatever color the element already
 *  had, rather than forcing one. */
export function nameColorStyle(color?: string | null): { color: string } | undefined {
  return color && (NAME_COLORS as readonly string[]).includes(color)
    ? { color: `var(--nc-${color})` }
    : undefined
}
