import { useEffect, useRef } from 'react'
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
        {children}
      </div>
    </div>
  )
}
