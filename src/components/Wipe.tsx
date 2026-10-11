import { useCallback, useEffect, useRef, useState } from 'react'
import { uiRate } from '../lib/lookFeel'

/**
 * The transition between the menu and a match.
 *
 * Inside the menu, moving between the grid and a page is the tile growing --
 * see Zoom.tsx. Crossing into a match, or back out of it, has no tile to grow
 * from: the two views share nothing, and React swaps one for the other in a
 * single frame, which reads as the screen glitching rather than as going
 * somewhere.
 *
 * So a leaning block sweeps across, the swap happens while it covers the
 * screen, and it carries on out the far side. Same skew as the menu, so the
 * whole app moves in one shape.
 */
const IN_MS = 260     // must match the wipe-in animation in styles.css
const OUT_MS = 300
/* The swap waits a little past the sweep rather than exactly on it. A CSS
   animation does not start on the frame its class is applied -- it starts on
   the next one -- so a swap timed to the millisecond lands a frame early and
   shows a sliver of the old view along the trailing edge. (The +50 below.) */

export function useWipe() {
  const [phase, setPhase] = useState<'idle' | 'in' | 'out'>('idle')
  const timers = useRef<number[]>([])

  useEffect(() => () => timers.current.forEach(window.clearTimeout), [])

  /**
   * Note what this does NOT do: check prefers-reduced-motion and skip. Asking
   * for less motion is not asking for a screen that changes between one frame
   * and the next -- that is the thing this exists to stop. The block still
   * covers, the swap still happens underneath it; the stylesheet just fades it
   * in place instead of sweeping it across. The timing is the same either way,
   * so there is one code path and not two.
   */
  const pending = useRef<(() => void) | null>(null)
  const running = useRef(false)

  const cross = useCallback((swap: () => void) => {
    // A crossing already under way takes the new destination and keeps its
    // own clock. Restarting the timers on every call was a real bug: a caller
    // that asks again more often than the 310ms swap -- an effect re-running
    // on a component that re-renders five times a second -- would push the
    // swap forward for ever, and the block would cover the screen and never
    // leave. Latest destination wins; the timing is not up for negotiation.
    pending.current = swap
    if (running.current) return

    running.current = true
    // 0220: the admin's menu-speed dial scales the sweep (the CSS divides by --ui-speed too).
    const k = uiRate()
    const swapMs = IN_MS / k + 50, outMs = OUT_MS / k
    timers.current.forEach(window.clearTimeout)
    timers.current = []
    setPhase('in')
    timers.current.push(
      window.setTimeout(() => {
        pending.current?.()
        pending.current = null
        setPhase('out')
      }, swapMs),
      window.setTimeout(() => {
        running.current = false
        setPhase('idle')
      }, swapMs + outMs),
    )
  }, [])

  const wipe = phase === 'idle' ? null : <div className={`wipe is-${phase}`} aria-hidden="true" />
  return { cross, wipe }
}
