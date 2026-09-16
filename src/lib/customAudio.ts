/**
 * The layer sfx.ts does not have: a sound one specific CARD carries, uploaded
 * through Admin Mode's card editor and stored in the 'audio' bucket (0040).
 *
 * This plays ALONGSIDE whatever sfx.ts already played for the same beat,
 * never instead of it. sfx.ts stays the whole game's baseline -- synthesised,
 * shipped with nothing to download -- and a card with nothing uploaded here
 * sounds exactly as it always has, because every function below does nothing
 * at all when its column is null. A real file, when there is one, plays on
 * top of the synthesised hit rather than replacing it, the same way a real
 * orchestra sits on top of a click track rather than waiting for it to stop.
 */
import { getSettings } from './settings'
import type { Card } from './types'

const COLUMN = {
  attack: 'audio_attack_url',
  ability: 'audio_ability_url',
  passive: 'audio_passive_url',
  walk: 'audio_walk_url',
} as const satisfies Record<string, keyof Card>

export type CardSoundKind = keyof typeof COLUMN

/** One HTMLAudioElement per play rather than a shared, reused element: two
 *  different cards can plausibly cue the same kind in the same beat (a
 *  passive proc alongside a hit, for instance), and a shared element would
 *  make the second one cut the first off. These are short clips; a handful
 *  of overlapping ones is not a resource problem worth the complexity of a
 *  pool. */
export function playCardSound(card: Card | null | undefined, kind: CardSoundKind) {
  if (!card) return
  const url = card[COLUMN[kind]] as string | null | undefined
  if (!url) return
  const vol = getSettings().sfx
  if (vol <= 0) return
  try {
    const el = new Audio(url)
    el.volume = Math.max(0, Math.min(1, vol))
    void el.play().catch(() => { /* autoplay can be refused before a gesture; not fatal */ })
  } catch {
    /* a browser that refuses to construct an Audio here is not a reason to
       throw in the middle of a combat animation */
  }
}
