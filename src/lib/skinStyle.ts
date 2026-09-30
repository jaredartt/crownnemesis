import type { CSSProperties } from 'react'
import type { FrameSkinData, NameColorSkinData, Skin, UnitSkinData } from './types'

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
  ring: '#c9d1dc', ring2: null, width: 4, glow: null, anim: 'none',
}
export const NAME_SKIN_DEFAULTS: NameColorSkinData = { color: '#2f4bff', color2: null, shimmer: false }

export const SHEENS = ['none', 'shine', 'holo', 'pulse'] as const
export const FRAME_ANIMS = ['none', 'pulse', 'spin'] as const

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
    ring: hex(x.ring, FRAME_SKIN_DEFAULTS.ring)!,
    ring2: hex(x.ring2, null),
    width: num(x.width, 2, 8, 4),
    glow: hex(x.glow, null),
    anim: (FRAME_ANIMS as readonly string[]).includes(x.anim as string) ? (x.anim as FrameSkinData['anim']) : 'none',
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

export function frameVars(skin: Skin | null | undefined): { style: CSSProperties; anim: string } | null {
  if (!skin || skin.kind !== 'frame') return null
  const d = readFrameData(skin.data)
  return {
    anim: d.anim,
    style: {
      '--fr-a': d.ring, '--fr-b': d.ring2 ?? d.ring, '--fr-w': `${d.width}px`, '--fr-glow': d.glow ?? 'transparent',
    } as CSSProperties,
  }
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
