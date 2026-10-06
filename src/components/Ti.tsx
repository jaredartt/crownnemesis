import type { CSSProperties } from 'react'
import { TI } from '../lib/tablerIcons'

/** One Tabler icon (https://tabler.io/icons). Colour is whatever the text colour
 *  is (currentColor), so an icon is recoloured by CSS exactly like the glyph it
 *  replaced. `filled` picks the solid drawing where Tabler has one. `size`
 *  ('1em', '16px'...) is only set where the icon stands in for a character; the
 *  icon set in Icons.tsx leaves its size to the stylesheet, as before. */
export function Ti({ name, filled, className, size, style }: {
  name: string
  filled?: boolean
  className?: string
  size?: number | string
  style?: CSSProperties
}) {
  const e = TI[name]
  const solid = !!(filled && e?.f)
  const html = (solid ? e?.f : e?.o ?? e?.f) ?? ''
  return (
    <svg
      className={className} viewBox="0 0 24 24" width={size} height={size} style={style}
      fill={solid ? 'currentColor' : 'none'} stroke={solid ? 'none' : 'currentColor'}
      strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"
      dangerouslySetInnerHTML={{ __html: html }}
    />
  )
}
