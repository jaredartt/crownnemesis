import { useEffect, useRef, useState } from 'react'
import { IconClose } from './Icons'
import { useT } from '../lib/i18n'

/**
 * A panel in the middle of the screen with the app dimmed and blurred behind
 * it. Escape closes it, so does the backdrop, and focus goes into it on open
 * so the keyboard is not left behind on the page underneath.
 */
export function Modal({
  title, onClose, children, centerTitle, titleNode,
}: {
  title: string
  onClose: () => void
  children: React.ReactNode
  /** Jared, on the match-results popup: "make it centered in the pop-up."
   *  Every other Modal call site keeps the left title / right-X header
   *  this file has always drawn -- this is one popup's own request, not a
   *  new house style, so it is an opt-in prop rather than a change to
   *  .modal-head itself. See .modal-head.is-centered in styles.css. */
  centerTitle?: boolean
  /** A richer stand-in for `title` inside the <h2> -- the match-results
   *  popup's own avatar-over-colored-name header, today. `title` stays a
   *  plain string regardless (it is still what aria-label reads), so a
   *  screen reader gets the same accessible name either way; titleNode is
   *  purely the sighted rendering. */
  titleNode?: React.ReactNode
}) {
  const t = useT()
  const box = useRef<HTMLDivElement>(null)
  const body = useRef<HTMLDivElement>(null)
  // A bug that only showed up once a Modal first held a text input a
  // person types into (My Kingdom's own edit dialog): onClose is an inline
  // arrow function at most call sites, so it is a new reference on every
  // parent render, including the one each keystroke causes by updating
  // state. With onClose in this effect's deps, that reran the effect and
  // its box.current?.focus() on every keystroke, yanking focus back to the
  // dialog's own frame a letter after it landed in the field. The ref lets
  // the effect run once, at mount, while still calling whatever onClose is
  // current when Escape is actually pressed.
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onCloseRef.current() }
    window.addEventListener('keydown', onKey)
    box.current?.focus()
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // Jared: people can't tell there's more to scroll in Settings, or in the
  // profile popup from the header's own avatar button -- and "apply it to
  // any other situation that needs this." Every popup in the app is this
  // one component, so the fix lives here once rather than in each modal's
  // own file: a bottom-edge fade that's only ever shown once we've actually
  // measured that there is more panel below the fold. Recomputed on scroll,
  // on the content's own size changing (e.g. ProfileCard's roster arriving
  // after its own fetch, well after this effect's first run), and on the
  // window resizing (mobile browser chrome showing/hiding changes how much
  // of a dvh-sized modal actually fits).
  //
  // First attempt used position: absolute + bottom: 0 on this div, which
  // LOOKED right in isolation but was wrong: per the CSS Overflow spec, an
  // absolutely-positioned descendant whose containing block is the scroll
  // container is itself part of that container's *scrollable overflow* --
  // it moves with the scrolled content instead of staying glued to the
  // visible edge. Jared, from a screenshot: "should be stuck at the bottom
  // of the window, not just put there" -- exactly that bug, the fade
  // drifting through the middle of the panel as you scrolled rather than
  // pinning to the bottom. position: sticky is the CSS tool actually built
  // for "pin within a scrolling ancestor, until you truly run out of
  // content" -- combined with a negative margin-top equal to its own
  // (JS-measured, since a % height needs a definite-height ancestor this
  // one only has via max-height/content) height, so it costs zero extra
  // scroll distance and detaches at exactly the true bottom rather than
  // one fade-height short of it or one past it.
  const [moreBelow, setMoreBelow] = useState(false)
  const [fadeH, setFadeH] = useState(0)
  useEffect(() => {
    const el = box.current
    if (!el) return
    const recompute = () => {
      setMoreBelow(el.scrollHeight - el.scrollTop - el.clientHeight > 2)
      setFadeH(Math.round(el.clientHeight * 0.25))
    }
    recompute()
    el.addEventListener('scroll', recompute, { passive: true })
    window.addEventListener('resize', recompute)
    const ro = new ResizeObserver(recompute)
    ro.observe(el)
    if (body.current) ro.observe(body.current)
    return () => {
      el.removeEventListener('scroll', recompute)
      window.removeEventListener('resize', recompute)
      ro.disconnect()
    }
  }, [])

  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div
        className="modal" role="dialog" aria-modal="true" aria-label={title}
        ref={box} tabIndex={-1}
      >
        <header className={`modal-head${centerTitle ? ' is-centered' : ''}`}>
          <h2>{titleNode ?? title}</h2>
          <button className="modal-x" onClick={onClose} aria-label={t('common.close')}>
            <IconClose />
          </button>
        </header>
        <div ref={body}>{children}</div>
        <div
          className={`modal-fade-bottom${moreBelow ? ' is-visible' : ''}`}
          style={{ height: fadeH, marginTop: -fadeH }}
          aria-hidden="true"
        />
      </div>
    </div>
  )
}
