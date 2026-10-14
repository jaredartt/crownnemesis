/**
 * Does the device the player is holding have a cursor that can HOVER?
 *
 * Jared, on the tutorial and My Kingdom hints: "press a card to know more on
 * mobile, hover over the card on desktop... conditionals according to the
 * viewport". What actually decides whether hover exists is the primary
 * pointer, not the width of the window -- a narrow desktop window still has a
 * mouse and a big tablet still has a finger -- so this asks the browser
 * `(hover: hover) and (pointer: fine)` rather than measuring pixels. The same
 * pair of media features is what styles.css's `@media (pointer: coarse)`
 * rules lean on, so the hint and the layout always agree.
 */
export function canHover(): boolean {
  try {
    return typeof matchMedia !== 'undefined' && matchMedia('(hover: hover) and (pointer: fine)').matches
  } catch {
    return false
  }
}
