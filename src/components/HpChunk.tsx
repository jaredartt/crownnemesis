import { useCallback, useEffect, useRef, useState } from 'react'

/* Jared: "when tokens lose or gain HP, the part of the change in HP (the part
   of the bar that is affected, negatively or positively) is temporary white,
   then turns red or blue, depending on the team, like mortal kombat ... in
   both tokens' HP and fight scene."

   One hook for every health bar (board token, Battle Royale token, fight
   scene). It watches the number the bar is DISPLAYING -- which is already
   the held/revealed value, so a hit shows up exactly when the bar moves --
   and when it changes, returns a <span> to render inside the bar, positioned
   over the slice of the bar that changed:
     - a LOSS leaves a white ghost where the lost health was; it holds, solid
       white, and then drains away toward what is left (the way fighting games
       do it -- it never fades into the team colour);
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

/* Jared: "the HP bar right-most rhomboid part width should always adjust to
   that unit's HP in that moment (1-3 characters)". The number's real width
   depends on the font, so it is measured rather than guessed: this is a
   callback ref for the number element, which writes its width to --numw on
   its parent (the bar's container), where the bar's clip-path reads it. */
export function useHpNumWidth() {
  const ro = useRef<ResizeObserver | null>(null)
  return useCallback((el: HTMLElement | null) => {
    ro.current?.disconnect()
    ro.current = null
    const host = el?.parentElement
    if (!el || !host) return
    const set = () => host.style.setProperty('--numw', `${el.offsetWidth}px`)
    set()
    if (typeof ResizeObserver !== 'undefined') {
      ro.current = new ResizeObserver(set)
      ro.current.observe(el)
    }
  }, [])
}
