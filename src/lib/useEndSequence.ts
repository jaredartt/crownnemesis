import { useEffect, useRef, useState } from 'react'

export type EndPhase = 'idle' | 'crown' | 'done'

/**
 * The end-of-match beat: (fight scene) -> crown breaks -> results popup.
 *
 * Why this is a hook with a tiny state machine. The winning blow reaches the
 * match screen a moment BEFORE the board reports that it is holding that
 * blow's fight scene (a child's effect cannot tell its parent inside the same
 * commit). The earlier version of this marked the match "handled" the instant a
 * winner existed and armed its timer in an effect that also depended on `busy`;
 * the fight scene then flipped `busy`, the effect's cleanup killed the timer,
 * and the "handled" mark meant nothing would ever try again: the crown played
 * hidden under the fight scene and the results never opened (Jared: "it is
 * literally what tells you who won").
 *
 * So here nothing is claimed before it has happened:
 *   1. `ready` and not `busy` for `settleMs` in a row -> start the crown (or, for
 *      a draw, open the results at once -- no crown fell).
 *   2. While the crown is breaking, a timer that depends only on the phase
 *      opens the results after `crownMs`.
 *   3. If the board never reports quiet, open the results anyway after
 *      `fallbackMs`.
 * `resetKey` (the match id) sends it back to 'idle' for the next match.
 */
export function useEndSequence({
  ready, draw, busy, resetKey, onOpenResults,
  settleMs = 400, crownMs, fallbackMs = 15000,
}: {
  /** There is a winner (or a draw) and everything needed to name it is loaded. */
  ready: boolean
  draw: boolean
  /** A fight scene is on screen / queued. */
  busy: boolean
  resetKey: string | null | undefined
  onOpenResults: () => void
  settleMs?: number
  crownMs: number
  fallbackMs?: number
}): { phase: EndPhase; reset: () => void } {
  const [phase, setPhase] = useState<EndPhase>('idle')
  const open = useRef(onOpenResults)
  open.current = onOpenResults

  // A new match (rematch, find another) starts over.
  const lastKey = useRef(resetKey)
  if (lastKey.current !== resetKey) {
    lastKey.current = resetKey
    if (phase !== 'idle') setPhase('idle')
  }

  useEffect(() => {
    if (!ready || phase !== 'idle' || busy) return
    const id = setTimeout(() => {
      if (draw) { setPhase('done'); open.current() } else setPhase('crown')
    }, settleMs)
    return () => clearTimeout(id)
  }, [ready, draw, busy, phase, resetKey, settleMs])

  useEffect(() => {
    if (phase !== 'crown') return
    const id = setTimeout(() => { setPhase('done'); open.current() }, crownMs)
    return () => clearTimeout(id)
  }, [phase, crownMs])

  useEffect(() => {
    if (!ready || phase !== 'idle') return
    const id = setTimeout(() => { setPhase('done'); open.current() }, fallbackMs)
    return () => clearTimeout(id)
  }, [ready, phase, resetKey, fallbackMs])

  return { phase, reset: () => setPhase('idle') }
}
