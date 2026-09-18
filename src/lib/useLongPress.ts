import { useEffect, useRef } from 'react'

/**
 * Shared with RoyaleBoard.tsx and Kingdoms.tsx (0068+: Phase 3/8 parity).
 * Originally lived only in Board.tsx -- extracted verbatim, not rewritten,
 * so the exact timing/slop/swallow behaviour every screen already relies
 * on stays identical everywhere it is used.
 */
/** How long a finger has to stay put before a card opens under it. Long
 *  enough not to fire on a tap, short enough that nobody thinks it is
 *  broken -- the same range a phone uses for its own press-and-hold. */
const LONG_MS = 420
/** And how far it may drift first. Past this it is a scroll or a drag, not a
 *  press, and a card that opens while somebody is dragging the board is a
 *  card in the way. */
const LONG_SLOP = 10

/**
 * Press and hold to read a card.
 *
 * A phone has no pointer, so the card that opens beside the board on a desktop
 * has nothing to open for. The strip under the board covers the unit you have
 * SELECTED, but selecting is also how you move -- so there was no way at all
 * to read a card belonging to the other side, or a tree, without committing to
 * something.
 *
 * Touch only, on purpose. A mouse already has hover, and a right-hand-side
 * card that also appeared after holding the left button down would fire every
 * time somebody started a drag.
 *
 * The tap that ends a long press must NOT also select, so the fired flag is
 * copied into `swallow` on the way up and read by the click handler that comes
 * after it -- pointerup has already reset everything else by then.
 *
 * Lifting does NOT close the card. It used to, which meant a card could only
 * be read with a finger held over the board -- and made the purple keywords on
 * it impossible to tap at all, since tapping means letting go first.
 */
export function useLongPress(onFire: () => void) {
  const timer = useRef<number | undefined>(undefined)
  const from = useRef<{ x: number; y: number } | null>(null)
  const fired = useRef(false)
  const swallow = useRef(false)

  const stop = () => {
    window.clearTimeout(timer.current)
    from.current = null
    if (fired.current) { fired.current = false; swallow.current = true }
  }
  useEffect(() => () => window.clearTimeout(timer.current), [])

  return {
    handlers: {
      onPointerDown(e: React.PointerEvent) {
        // Disarm first. `swallow` is set on the way up and meant to be eaten
        // by the click that follows -- but since a peeked card puts a scrim in
        // the way, that click can land somewhere else entirely and never
        // arrive. Left armed it ate the NEXT ordinary tap on this unit, so a
        // long press made the unit unselectable exactly once, which is the
        // kind of bug nobody reports and everybody feels.
        swallow.current = false
        if (e.pointerType !== 'touch') return
        from.current = { x: e.clientX, y: e.clientY }
        fired.current = false
        window.clearTimeout(timer.current)
        timer.current = window.setTimeout(() => { fired.current = true; onFire() }, LONG_MS)
      },
      onPointerMove(e: React.PointerEvent) {
        const a = from.current
        if (!a) return
        if (Math.hypot(e.clientX - a.x, e.clientY - a.y) > LONG_SLOP) stop()
      },
      onPointerUp: stop,
      onPointerCancel: stop,
      onContextMenu(e: React.MouseEvent) { if (swallow.current) e.preventDefault() },
    },
    /**
     * True once, for the click that follows the press that opened a card.
     *
     * A caller that gets `true` must ALSO stop the event. Ignoring it is not
     * enough: the board's own background handler clears the selection, so a
     * click the unit declines to act on but lets past is a long press that
     * puts the unit down -- which is exactly what "reading a card must change
     * nothing" is not.
     */
    swallowed() {
      if (!swallow.current) return false
      swallow.current = false
      return true
    },
  }
}

