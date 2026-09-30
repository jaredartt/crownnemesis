import type { Skin } from '../lib/types'
import { nameSkinStyle } from '../lib/skinStyle'
import { Avatar } from './Avatar'

/**
 * 0188: what a skin looks like, drawn from the skin's own `data`. One place,
 * used by the player's picker (Profile) and by the admin editor's live
 * preview -- so what the admin tunes is exactly what a player will see.
 */
export function FramePreview({ skin, face, name, size = 44 }: { skin: Skin; face: string | null; name: string; size?: number }) {
  return <Avatar slug={face} name={name} size={size} frame={skin} />
}

export function NameSkinPreview({ skin, text }: { skin: Skin; text: string }) {
  return <span className="skinprev-name" style={nameSkinStyle(skin)}>{text}</span>
}

export function SkinPreview({ skin, face, name }: { skin: Skin; face: string | null; name: string }) {
  if (skin.kind === 'frame') return <FramePreview skin={skin} face={face} name={name} />
  return <NameSkinPreview skin={skin} text={name || 'Name'} />
}
