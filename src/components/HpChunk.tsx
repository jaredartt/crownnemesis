import { useEffect, useRef, useState } from 'react'

/* Jared: "when tokens lose or gain HP, the part of the change in HP (the part
   of the bar that is affected, negatively or positively) is temporary white,
   then turns red or blue, depending on the team, like mortal kombat ... in
   both tokens' HP and fight scene."

   One hook for every health bar (board token, Battle Royale token, fight
   scene). It watches the number the bar is DISPLAYING -- which is already
   the held/revealed value, so a hit shows up exactly when the bar moves --
   and when it changes, returns a <span> to render inside the bar, positioned
   over the slice of the bar that changed:
     - a LOSS leaves a white ghost where the lost health was, which turns the
       team colour and then drains away toward what is left;
     - a GAIN paints the newly filled slice white, then it settles into the
       team colour.
   The team colour comes from the bar's own --hp-col (see .hp-chunk in
   styles.css), so blue/red follows whatever rule that bar already uses. */
export function useHpChunk(hp: number, maxHp: number) {
  const prev = useRef(hp)
  const [chunk, setChunk] = useState<{ from: number; to: number; key: number } | null>(null)

  useEffect(() => {
    if (prev.current === hp) return
    const from = prev.current
    prev.current = hp
    setChunk((c) => ({ from, to: hp, key: (c?.key ?? 0) + 1 }))
    const id = window.setTimeout(() => setChunk(null), 1300)
    return () => window.clearTimeout(id)
  }, [hp])

  if (!chunk || maxHp <= 0) return null
  const pct = (v: number) => Math.max(0, Math.min(100, (v / maxHp) * 100))
  const a = pct(chunk.from)
  const b = pct(chunk.to)
  const left = Math.min(a, b)
  const width = Math.abs(a - b)
  if (width <= 0) return null
  return (
    <span
      key={chunk.key}
      className={`hp-chunk ${chunk.to < chunk.from ? 'is-loss' : 'is-gain'}`}
      style={{ left: `${left}%`, width: `${width}%` }}
      aria-hidden="true"
    />
  )
}
