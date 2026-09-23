import { useEffect, useRef, useState } from 'react'
import { selectKingdom } from '../lib/api'
import { fieldable, notFieldable, unreadyText } from '../lib/kingdoms'
import type { Profile } from '../lib/types'
import { useT } from '../lib/i18n'
import { useCardsBySlug } from '../lib/useCards'
import { Avatar } from './Avatar'

/**
 * Which army you are about to take in, and a way to change your mind.
 *
 * It belongs on the pre-battle screens because that is where "which kingdom"
 * is a live question, and it stops being one the moment an opponent arrives:
 * the server builds both armies out of deck_of() inside join_match, so the
 * last instant this can matter to a friends room is while it is still empty.
 * After that it would be a control that looks like it does something.
 *
 * Absent when there is only one kingdom. A switch with one position is not a
 * switch, and the pre-battle screens are already busy enough without a chip
 * telling somebody with one army which army they have.
 *
 * A kingdom that cannot be fielded is listed and disabled with the reason
 * beside it, rather than hidden. Hiding it makes the list disagree with the
 * shelf in My Kingdom for reasons nobody can see from here.
 */
export function KingdomSwitch({
  profile, onProfile, className = '', placeholder, alwaysShow = false, onManage,
}: {
  profile: Profile
  onProfile: (patch: Partial<Profile>) => void
  className?: string
  /** What the trigger reads before a kingdom is chosen. Defaults to
   *  "The default five" -- Ranked overrides it with "Choose your deck",
   *  since that screen has nowhere else this switch's own job is done. */
  placeholder?: string
  /** Skips the "absent with one kingdom" rule below. Ranked wants the
   *  trigger on screen even for an account with a single kingdom, since it
   *  is the ONLY door open() there for picking one -- everywhere else this
   *  stays a chip that only earns its place once there is a real choice. */
  alwaysShow?: boolean
  /** Renders one more row under the list, past a divider: a way out to the
   *  full kingdom editor for whoever wants to build a new one or fix a
   *  deck that showed up disabled. Takes the clicked element, the same way
   *  a tile click hands zoomTo something to grow from. Omitted entirely
   *  (Vs Bots, Vs Friends) this switch is just the quick switch it always
   *  was. */
  onManage?: (el: HTMLElement) => void
}) {
  const t = useT()
  const cards = useCardsBySlug()
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const box = useRef<HTMLDivElement>(null)

  const list = profile.kingdoms ?? []
  const current = list.find((k) => k.id === profile.kingdom) ?? null
  const nameOf = (id: string) =>
    list.find((k) => k.id === id)?.name ||
    t('kingdom.untitled', { n: list.findIndex((k) => k.id === id) + 1 })

  useEffect(() => {
    if (!open) return
    const away = (e: MouseEvent) => {
      if (!box.current?.contains(e.target as Node)) setOpen(false)
    }
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    // mousedown rather than click, so the press that opened this one does not
    // also close it on its way back up.
    document.addEventListener('mousedown', away)
    window.addEventListener('keydown', key)
    return () => {
      document.removeEventListener('mousedown', away)
      window.removeEventListener('keydown', key)
    }
  }, [open])

  if (list.length < 2 && !alwaysShow) return null

  const ready = current ? fieldable(current.deck, cards) : false

  async function choose(id: string) {
    setBusy(true)
    try {
      const got = await selectKingdom(id)
      onProfile({ kingdom: got })
      setOpen(false)
    } catch {
      // Nothing to report here that the player can act on: the kingdom they
      // asked for is still there and still theirs, and My Kingdom is where a
      // failure to change it has somewhere to be said.
      setOpen(false)
    } finally { setBusy(false) }
  }

  return (
    <div className={`kswitch ${className}`.trim()} ref={box}>
      <button
        type="button" className="kswitch-btn" disabled={busy}
        aria-expanded={open} aria-haspopup="listbox"
        onClick={() => setOpen((o) => !o)}
      >
        <Avatar
          slug={current ? (current.icon ?? current.deck[0] ?? null) : null}
          name={current ? nameOf(current.id) : '?'} size={24}
        />
        <span className="kswitch-name">
          {ready && current ? nameOf(current.id) : (placeholder ?? t('kingdom.defaultFive'))}
        </span>
        <span className="kswitch-caret" aria-hidden="true">▾</span>
      </button>

      {open && (
        <ul className="kswitch-menu" role="listbox">
          {list.map((k, i) => {
            const why = notFieldable(k.deck, cards)
            return (
              <li key={k.id}>
                <button
                  type="button" role="option" disabled={!!why || busy}
                  aria-selected={k.id === profile.kingdom}
                  className={k.id === profile.kingdom ? 'is-on' : ''}
                  onClick={() => void choose(k.id)}
                >
                  <Avatar
                    slug={k.icon ?? k.deck[0] ?? null}
                    name={k.name || String(i + 1)} size={22}
                  />
                  <span className="kswitch-mname">
                    {k.name || t('kingdom.untitled', { n: i + 1 })}
                  </span>
                  <span className="kswitch-mwhy">
                    {why ? unreadyText(why, k.deck, t) : ''}
                  </span>
                </button>
              </li>
            )
          })}
          {onManage && (
            <>
              <li className="kswitch-divider" role="presentation" aria-hidden="true" />
              <li>
                <button
                  type="button" className="kswitch-manage"
                  onClick={(e) => { setOpen(false); onManage(e.currentTarget) }}
                >
                  {t('kingdom.manage')}
                </button>
              </li>
            </>
          )}
        </ul>
      )}
    </div>
  )
}
