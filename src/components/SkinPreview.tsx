import type { CSSProperties } from 'react'
import type { Skin } from '../lib/types'
import { nameSkinStyle, unitSkinVars } from '../lib/skinStyle'
import { Avatar } from './Avatar'

/**
 * 0188: what a skin looks like, drawn from the skin's own `data`. One place,
 * used by the player's picker (Profile) and by the admin editor's live
 * preview -- so what the admin tunes is exactly what a player will see.
 * (The board wears unit skins with the same CSS custom properties and the
 * same .unit-sheen overlay; see styles.css "0188".)
 */
export function UnitSkinPreview({ skin, size = 56 }: { skin: Skin; size?: number }) {
  const d = skin.data as { sheen?: string }
  return (
    <span className="skinprev-unit" style={{ width: size, height: size, ...unitSkinVars(skin) } as CSSProperties}>
      <b className="skinprev-unit-art" aria-hidden="true">♞</b>
      <i className="unit-sheen" data-sheen={d.sheen ?? 'none'} aria-hidden="true" />
    </span>
  )
}

export function FramePreview({ skin, face, name, size = 44 }: { skin: Skin; face: string | null; name: string; size?: number }) {
  return <Avatar slug={face} name={name} size={size} frame={skin} />
}

export function NameSkinPreview({ skin, text }: { skin: Skin; text: string }) {
  return <span className="skinprev-name" style={nameSkinStyle(skin)}>{text}</span>
}

export function SkinPreview({ skin, face, name }: { skin: Skin; face: string | null; name: string }) {
  if (skin.kind === 'unit') return <UnitSkinPreview skin={skin} />
  if (skin.kind === 'frame') return <FramePreview skin={skin} face={face} name={name} />
  return <NameSkinPreview skin={skin} text={name || 'Name'} />
}
