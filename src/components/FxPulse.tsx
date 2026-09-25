import type { CSSProperties } from 'react'

/**
 * THE NOTORIOUS PULSE -- a loud, one-shot signal that something happened to
 * this unit: a heal landing, or a status landing. Deliberately louder than
 * StatusBurst's own flash/ring (a modest pop, sized to the burst itself) --
 * this is the whole token announcing the moment: two thick rings rocket
 * outward past the card's own edge in quick succession and a bright wash
 * floods the card, all in one colour passed in as `color` -- Jared: "it
 * needs to be notorious, eye-catching." Green for a heal (HealBurst.tsx);
 * each affliction's own colour for a status landing (StatusBurst.tsx),
 * which is why this lives as its own component instead of being copied
 * into both -- "a notorious pulse also ... of the color of that status."
 *
 * Pure CSS, one custom property (`--fx-color`), no JS after mount -- same
 * construction as HitBurst/StatusBurst next to it.
 */
export function FxPulse({ color }: { color: string }) {
  return (
    <div className="fxpulse" style={{ '--fx-color': color } as CSSProperties} aria-hidden="true">
      <i className="fxpulse-wash" />
      <i className="fxpulse-ring" />
      <i className="fxpulse-ring2" />
    </div>
  )
}
