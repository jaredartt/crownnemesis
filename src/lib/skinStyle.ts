import type { CSSProperties } from 'react'
import { FRAME_STYLES, type FrameSkinData, type NameColorSkinData, type Skin, type UnitSkinData } from './types'

/**
 * 0188: turns a skin's `data` (admin-typed JSON) into inline style. Every
 * field is validated here rather than trusted -- a bad hex or an unknown
 * sheen falls back to something safe instead of producing broken CSS.
 */
const HEX = /^#[0-9a-fA-F]{6}$/
export const hex = (v: unknown, fallback: string | null): string | null =>
  typeof v === 'string' && HEX.test(v) ? v : fallback
const num = (v: unknown, lo: number, hi: number, fb: number): number =>
  typeof v === 'number' && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : fb

export const UNIT_SKIN_DEFAULTS: UnitSkinData = {
  rim: '#8a94a6', rim_width: 3, glow: null, glow_size: 0,
  sheen: 'none', sheen_color: '#ffffff', tint: null, tint_alpha: 0,
}
export const FRAME_SKIN_DEFAULTS: FrameSkinData = {
  style: 'solid', ring: '#c9d1dc', ring2: null, ring3: null, angle: 135,
}
export const NAME_SKIN_DEFAULTS: NameColorSkinData = { color: '#2f4bff', color2: null, shimmer: false }

export const SHEENS = ['none', 'shine', 'holo', 'pulse'] as const
export { FRAME_STYLES }

export function readUnitData(d: Record<string, unknown> | undefined): UnitSkinData {
  const x = d ?? {}
  return {
    rim: hex(x.rim, UNIT_SKIN_DEFAULTS.rim)!,
    rim_width: num(x.rim_width, 1, 6, 3),
    glow: hex(x.glow, null),
    glow_size: num(x.glow_size, 0, 24, 0),
    sheen: (SHEENS as readonly string[]).includes(x.sheen as string) ? (x.sheen as UnitSkinData['sheen']) : 'none',
    sheen_color: hex(x.sheen_color, '#ffffff')!,
    tint: hex(x.tint, null),
    tint_alpha: num(x.tint_alpha, 0, 0.5, 0),
  }
}

export function readFrameData(d: Record<string, unknown> | undefined): FrameSkinData {
  const x = d ?? {}
  return {
    style: (FRAME_STYLES as readonly string[]).includes(x.style as string) ? (x.style as FrameSkinData['style']) : 'solid',
    ring: hex(x.ring, FRAME_SKIN_DEFAULTS.ring)!,
    ring2: hex(x.ring2, null),
    ring3: hex(x.ring3, null),
    angle: num(x.angle, 0, 360, 135),
  }
}

export function readNameData(d: Record<string, unknown> | undefined): NameColorSkinData {
  const x = d ?? {}
  const v = typeof x.var === 'string' && /^--nc-[a-z]+$/.test(x.var) ? x.var : undefined
  return {
    var: v,
    color: hex(x.color, NAME_SKIN_DEFAULTS.color!)!,
    color2: hex(x.color2, null),
    shimmer: x.shimmer === true,
  }
}

/** CSS custom properties Board.tsx puts on a unit wearing this skin. */
export function unitSkinVars(skin: Skin | null | undefined): CSSProperties | undefined {
  if (!skin || skin.kind !== 'unit') return undefined
  const d = readUnitData(skin.data)
  return {
    '--sk-rim': d.rim,
    '--sk-w': `${d.rim_width}px`,
    '--sk-glow': d.glow ?? 'transparent',
    '--sk-glow-size': `${d.glow_size}px`,
    '--sk-sheen': d.sheen_color,
    '--sk-tint': d.tint ?? 'transparent',
    '--sk-tint-a': d.tint ? d.tint_alpha : 0,
  } as CSSProperties
}

/** The ring's paint, as one CSS <image>. `--fr-w` (the band's thickness, set
 *  by Avatar from its own size) is referenced for the radial kind, whose
 *  colours run from the inner edge of the band to the outer one. */
export function frameGradient(d: FrameSkinData): string {
  const a = d.ring
  const b = d.ring2 ?? d.ring
  const c = d.ring3
  switch (d.style) {
    case 'linear':
      return `linear-gradient(${d.angle}deg, ${a}, ${c ? `${b}, ${c}` : b})`
    case 'conic':
      return `conic-gradient(from ${d.angle}deg, ${a}, ${c ? `${b}, ${c}` : b}, ${a})`
    case 'radial':
      return `radial-gradient(circle closest-side, ${a} calc(100% - var(--fr-w)), ${c ? `${c} calc(100% - var(--fr-w) / 2), ` : ''}${b} 100%)`
    case 'duo':
      return `conic-gradient(from ${d.angle}deg, ${a} 0 50%, ${b} 50% 100%)`
    default:
      return a
  }
}

/** Custom properties for an avatar wearing this frame. Width is NOT here --
 *  it is a fixed fraction of the avatar, decided where the size is known. */
export function frameVars(skin: Skin | null | undefined): { style: CSSProperties } | null {
  if (!skin || skin.kind !== 'frame') return null
  return { style: { '--fr-bg': frameGradient(readFrameData(skin.data)) } as CSSProperties }
}

/** Inline style that colours a name for this skin. */
export function nameSkinStyle(skin: Skin | null | undefined): CSSProperties | undefined {
  if (!skin || skin.kind !== 'name_color') return undefined
  const d = readNameData(skin.data)
  if (d.var) return { color: `var(${d.var})` }
  if (d.color2) {
    const base: CSSProperties = {
      backgroundImage: `linear-gradient(90deg, ${d.color}, ${d.color2}, ${d.color})`,
      backgroundSize: '200% 100%',
      WebkitBackgroundClip: 'text', backgroundClip: 'text',
      color: 'transparent', WebkitTextFillColor: 'transparent',
    }
    return d.shimmer ? { ...base, animation: 'nc-shimmer 3.2s linear infinite' } : base
  }
  return { color: d.color ?? undefined }
}
