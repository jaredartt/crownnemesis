import { useCallback, useEffect, useRef, useState } from 'react'
import { lessMotion } from '../lib/settings'
import { useT } from '../lib/i18n'

/**
 * The Smash-menu transition: the tile you pressed grows until it IS the page.
 *
 * A FLIP, not a route change. On the click we take the tile's rectangle, drop
 * a solid block of its own colour exactly over it, and let CSS carry that block
 * out past the edges of the screen. The page mounts underneath with a wash of
 * the same colour already filling it, so the moment the block is removed there
 * is nothing to see -- the wash then shrinks to a header band, and that shrink
 * is what makes it read as arriving somewhere rather than as a panel opening.
 *
 * The block NEVER straightens up. It used to animate its skew back to zero on
 * the way out, which meant the shape you clicked turned into a different shape
 * before it left, and the eye reads that as a pop rather than as a move. It now
 * keeps the menu's lean the whole way and simply grows past the corners -- one
 * scale and one translate, both on the GPU, and no geometry change at all.
 */
export interface ZoomTarget {
  id: string
  tint: string
}

// Jared: clicking Ranked/Vs Bots/Vs Friends "takes like half a second...
// I don't know if it's loading or if it's a bug". It was neither -- both
// legs of the transition (this block's own grow, then .page-wash's own
// shrink in styles.css) are real, deliberate animation, and 360ms + 420ms
// of it back to back reads exactly like a stall even though nothing was
// ever waiting on the network. Trimmed to 260ms + 320ms (see .page-wash),
// which keeps the same two-beat "arriving somewhere" shape at a pace that
// reads as responsive instead of as a spinner.
const OUT_MS = 260
const SKEW = -8      // the menu's lean, in degrees; the block keeps it throughout

/**
 * How far this particular tile has to grow to swallow the screen. The 1.6 /
 * 1.5 are slack for the lean and for the corners a skewed rectangle leaves
 * uncovered -- cheaper than the trigonometry, and the block is a flat colour
 * so nobody can tell it overshot. Recomputed on the way back rather than
 * remembered, in case the window changed size while the page was open.
 */
function growFrom(r: DOMRect) {
  const s = Math.max((innerWidth * 1.6) / r.width, (innerHeight * 1.5) / r.height)
  const tx = innerWidth / 2 - (r.left + r.width / 2)
  const ty = innerHeight / 2 - (r.top + r.height / 2)
  return `translate(${tx}px, ${ty}px) scale(${s}) skewX(${SKEW}deg)`
}

/**
 * One step of "how did we get here": the page we were on before a zoomTo,
 * and the rect of whatever was clicked to leave it. Pushed on every zoomTo,
 * popped on every close -- a stack, not a single slot, because a page can
 * open another page without the first one ever having closed (Ranked's
 * "choose your deck" opens Team while Ranked is still the page underneath
 * it). Popping one gets you back exactly one screen, into the exact spot
 * you left it from, however deep the stack goes.
 */
interface Step { page: string | null; rect: DOMRect }

export function useZoom() {
  const [rect, setRect] = useState<DOMRect | null>(null)
  const [grow, setGrow] = useState('')
  const [tint, setTint] = useState('#000')
  const [open, setOpen] = useState(false)
  // Only the trip back needs this: opening always ends with the block
  // covered by .page-wash's own matching colour (see that div's own
  // comment), so removing it is invisible either way. Closing lands back
  // on the menu itself -- no wash there to hide the cut -- so it fades on
  // its own instead, timed to reach 0 exactly when the timeout below
  // unmounts it.
  const [closing, setClosing] = useState(false)
  const [page, setPageState] = useState<string | null>(null)
  // Mirrors `page` synchronously, so zoomTo always knows what page it is
  // LEAVING even when called back to back before React re-renders --
  // `page` itself can lag a tick behind in that case, and the history
  // stack has to be exact or "back" starts skipping steps.
  const pageRef = useRef<string | null>(null)
  const history = useRef<Step[]>([])
  const timer = useRef<number | undefined>(undefined)

  // The setting in Settings, or the one in the operating system. Either.
  const reduced = lessMotion()

  const setPage = useCallback((p: string | null) => {
    pageRef.current = p
    setPageState(p)
  }, [])

  const zoomTo = useCallback(
    (el: HTMLElement, target: ZoomTarget) => {
      const r = el.getBoundingClientRect()
      history.current.push({ page: pageRef.current, rect: r })
      setTint(target.tint)
      if (reduced) {
        setPage(target.id)
        return
      }
      setGrow(growFrom(r))
      setRect(r)
      setOpen(false)
      setClosing(false)
      // one frame at the tile's size, then let the transition do the rest
      requestAnimationFrame(() => requestAnimationFrame(() => setOpen(true)))
      window.clearTimeout(timer.current)
      timer.current = window.setTimeout(() => {
        setPage(target.id)
        setRect(null)
      }, OUT_MS)
    },
    [reduced, setPage],
  )

  /**
   * Leaving runs the same move backwards -- one step of `history`, not all
   * the way to the main menu. The block is mounted already at full size --
   * there is no previous state for it to transition from, so that first
   * frame simply paints -- the previous page is dropped underneath it in
   * the same commit, and only then does it shrink back into whatever was
   * clicked to leave that page, wherever on screen that was.
   */
  const close = useCallback(() => {
    const step = history.current.pop()
    const r = step ? step.rect : null
    const dest = step ? step.page : null
    if (reduced || !r) {
      setPage(dest); setRect(null); setOpen(false); setClosing(false)
      return
    }
    setGrow(growFrom(r))
    setRect(r)
    setOpen(true)     // painted, not animated: nothing to come from
    setClosing(false)
    setPage(dest)
    // Same double-rAF as zoomTo's: shrink and fade start together, on the
    // frame after the full-size block has actually painted.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      setOpen(false)
      setClosing(true)
    }))
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => setRect(null), OUT_MS)
  }, [reduced, setPage])

  useEffect(() => () => window.clearTimeout(timer.current), [])

  const zoomer = rect ? (
    <div
      className={`zoomer${open ? ' is-open' : ''}`}
      style={{
        left: rect.left, top: rect.top, width: rect.width, height: rect.height,
        background: tint,
        transform: open ? grow : `translate(0px, 0px) scale(1) skewX(${SKEW}deg)`,
        opacity: closing ? 0 : 1,
      }}
      aria-hidden="true"
    />
  ) : null

  return { zoomTo, close, page, tint, zoomer }
}

/** A menu destination: full bleed, its own colour, and a way back.
 *
 * Jared: the old full-width coloured bar (.page-head, 86px -- 66px on a
 * phone) "takes way so much space" on a phone or tablet, pushing every
 * page's own content down by that much before it has even started. One
 * small rhomboid in the page's own top-left corner -- the same leaning
 * shape the front menu's own tiles already use (see .mtile in styles.css)
 * -- says exactly the same two things the bar said (where this is, how to
 * leave it) in a fraction of the height, and it says it for every page at
 * once: every page still goes through this one shared component, so this
 * is the only place that needed to change. The whole badge is the back
 * button now (a bigger, easier target than the old separate circle was),
 * with the title read out in its aria-label alongside "back to the menu"
 * for anyone not seeing the arrow. */
export function Page({
  title, tint, onClose, wide, children,
}: {
  title: string
  tint: string
  onClose: () => void
  /** Edge to edge instead of a reading column. For pages that are pictures. */
  wide?: boolean
  children: React.ReactNode
}) {
  const t = useT()
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return (
    <section className="page" style={{ '--tint': tint } as React.CSSProperties}>
      <div className="page-wash" aria-hidden="true" />
      <button
        type="button" className="page-badge" onClick={onClose}
        aria-label={`${t('common.backToMenu')}: ${title}`}
      >
        <span className="page-badge-inner">
          <span className="page-badge-arrow" aria-hidden="true">←</span>
          <span className="page-badge-title">{title}</span>
        </span>
      </button>
      <div className={`page-body${wide ? ' is-wide' : ''}`}>{children}</div>
    </section>
  )
}
