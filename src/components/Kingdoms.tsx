import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { deleteKingdom, saveKingdom, selectKingdom } from '../lib/api'
import {
  KINGDOM_CAP, KINGDOM_NAME_MAX, cleanDeck, fieldable, isBlank, kingdomIcon,
  newKingdomId, notFieldable, type Unready, unreadyText,
} from '../lib/kingdoms'
import {
  DECK_SIZE, reachText, type Card, type Kingdom, type Profile, unitPower,
} from '../lib/types'
import { artUrl } from '../lib/art'
import { abilityText, useClassName, useT } from '../lib/i18n'
import { Ability } from './Ability'
import { Avatar } from './Avatar'
import { Modal } from './Modal'
import { CardBigCard } from './BigCard'
import { useLongPress } from '../lib/useLongPress'

/**
 * My Kingdom: ten of them, and the one you field.
 *
 * THE ONE RULE THAT DECIDES THE WHOLE SCREEN
 *
 * A kingdom becomes the one you field the moment it is a kingdom -- five cards
 * and exactly one crown -- whether that is because you just finished it or
 * because you opened one that already was. An INCOMPLETE one never displaces a
 * finished one.
 *
 * That is the old "a team saves itself the moment it is a team" carried up to
 * ten, and it is the only rule here that needs stating twice. The alternative
 * -- opening a kingdom fields it, full stop -- means that wandering into a
 * half-built one silently swaps your army for the default five, which is
 * exactly the failure 0024 split relaxed-editor from strict-match to avoid. A
 * separate "use this one" button is the other alternative, and it asks a
 * question nobody has: of course the kingdom you just finished is the one you
 * want.
 *
 * The only cost is that opening a finished kingdom to look at it does field
 * it. Which is why what you are fielding is written under the grid, on every
 * chip, and in the corner of every pre-battle screen.
 *
 * THERE IS STILL NO SAVE BUTTON. Everything -- a card, a rename, a mark -- is
 * pushed after a short pause, which is also what makes a burst of taps one
 * write instead of five.
 */

/** Long enough that typing a name is one write, short enough that tapping a
 *  card and looking up feels like it already happened. */
const SAVE_MS = 450

/** The roster grid's own one-shot entrance, played once per visit to this
 *  screen (Lobby.tsx conditionally renders Kingdoms, so opening My Kingdom
 *  always means a fresh mount -- no reset-on-change trick needed here the
 *  way Board.tsx needs one for a rematch, since this component never stays
 *  mounted across two different "openings"). Same three numbers as
 *  Board.tsx's REVEAL_START_MS/REVEAL_STEP_MS/LANDING_MS. */
const KINGDOM_REVEAL_START_MS = 200
const KINGDOM_REVEAL_STEP_MS = 70
const KINGDOM_LANDING_MS = 650

/** Which pop-up title fits which of notFieldable's reasons -- see the
 *  comment on the modal itself, below, for `hasRetired`'s borrowed one. */
const SAVE_BLOCKED_TITLE: Record<Unready, string> = {
  tooFew: 'kingdom.needFiveTitle',
  noCrown: 'kingdom.needKingTitle',
  twoCrowns: 'kingdom.needOneKingTitle',
  hasRetired: 'kingdom.needFiveTitle',
}

const keyOf = (k: Kingdom) => JSON.stringify([k.name, k.icon, k.deck])
const blank = (): Kingdom => ({ id: newKingdomId(), name: null, icon: null, deck: [] })

/** The roster sorter's own field list -- 'none' keeps the roster in
 *  whatever order it arrived in (the default, and the only option with no
 *  direction toggle, since "unsorted, but backwards" is not a thing). */
type SortField = 'none' | 'name' | 'class' | 'hp' | 'atk' | 'mov' | 'range'
type SortDir = 'asc' | 'desc'

/** Pulled out of the component so it can be a plain, testable function of
 *  its inputs rather than a `useMemo` body -- `className` is passed in
 *  (rather than called again in here) because it is itself a hook's
 *  return value, not something this function is allowed to call. Stable
 *  either way: `Array.prototype.sort` is guaranteed stable since ES2019,
 *  so two cards tied on the chosen field keep whatever relative order
 *  `roster` already had them in, rather than jittering on every re-sort. */
function sortRoster(roster: Card[], field: SortField, dir: SortDir, className: (role: string) => string): Card[] {
  if (field === 'none') return roster
  const sign = dir === 'asc' ? 1 : -1
  const key = (c: Card): number | string => {
    switch (field) {
      case 'name': return c.name
      case 'class': return className(c.role)
      case 'hp': return c.hp
      case 'atk': return unitPower(c)
      case 'mov': return c.mov
      case 'range': return c.range
    }
  }
  return [...roster].sort((a, b) => {
    const ka = key(a), kb = key(b)
    const cmp = typeof ka === 'string' ? ka.localeCompare(kb as string) : ka - (kb as number)
    return cmp * sign
  })
}

export function Kingdoms({ profile, roster, onProfile, onDirtyChange }: {
  profile: Profile
  roster: Card[]
  onProfile: (patch: Partial<Profile>) => void
  /** Told every time "is there anything on this shelf the server has not
   *  confirmed yet" changes, so Lobby.tsx -- which owns the door out of this
   *  page (Page's back arrow / Escape, in Zoom.tsx) -- knows whether to ask
   *  before letting you through it. Optional so nothing else that renders
   *  this page (there is nothing else, today) is forced to wire it up. */
  onDirtyChange?: (dirty: boolean) => void
}) {
  const t = useT()
  const className = useClassName()
  const cards = useMemo(() => new Map(roster.map((c) => [c.slug, c])), [roster])

  // Jared: "a sorter thing inside My Kingdom to find cards by class, HP,
  // attack, movement, range (ascending and descending), and even by name."
  // Then, once this existed: "wait, but I can't look for a specific class
  // or type a name" -- sorting by name or class only REORDERS the grid, it
  // doesn't narrow it, so "find Mako" still meant scanning the whole
  // roster for wherever the alphabet put her. That is a search box and a
  // class filter, a different job from the sort control above, so they
  // sit beside it rather than folded into it: the sort's own "name" and
  // "class" options are left in too, since ordering everyone alphabetically
  // (or by class) without hiding anyone is still its own useful thing.
  // None of this touches `roster` (the prop) itself -- `cards`, the
  // reveal-delay map below, and the deck-picking logic all key off card
  // slug/id rather than array position or presence in the visible list,
  // so a card that's filtered out of view is still in its deck if it was
  // picked; only what's ON SCREEN changes.
  const [search, setSearch] = useState('')
  const [classFilter, setClassFilter] = useState<string>('all')
  // Built from the roster itself rather than a hard-coded role list, so a
  // brand-new class doesn't need this screen edited to be filterable --
  // and translated + alphabetised so the order on screen doesn't depend on
  // whatever order the database happens to return roles in.
  const classOptions = useMemo(
    () => Array.from(new Set(roster.map((c) => c.role)))
      .sort((a, b) => className(a).localeCompare(className(b))),
    [roster, className],
  )
  // "Attack" sorts by the same number the card itself shows (`unitPower`)
  // -- a healer's own card shows a power stat under the same box a
  // fighter's damage sits in (see BigCard.tsx), so sorting by "attack" has
  // to read that column, not raw `dmin`/`dmax`, or a healer would sort as
  // if it hit for zero. "Class" sorts by the translated class name, the
  // same word the card itself is labelled with, so the order groups the
  // way the language on screen groups them.
  const [sortField, setSortField] = useState<SortField>('none')
  const [sortDir, setSortDir] = useState<SortDir>('asc')
  const visibleRoster = useMemo(() => {
    let arr = roster
    if (classFilter !== 'all') arr = arr.filter((c) => c.role === classFilter)
    const q = search.trim().toLowerCase()
    if (q) arr = arr.filter((c) => c.name.toLowerCase().includes(q))
    return sortRoster(arr, sortField, sortDir, className)
  }, [roster, classFilter, search, sortField, sortDir, className])

  // The board's own army-entrance effect, borrowed for this screen's own
  // army -- Jared: "I want to have that same card-revealing effect when you
  // open My Kingdom, so all units appear smoothly from left to right." One
  // wave, not two (there is only ever one side here), and "left to right" is
  // just the roster's own array order -- `.roster-grid` is a plain CSS grid
  // (grid-auto-flow: row, its default), so the order things are RENDERED in
  // already reads left to right, top to bottom, with no coordinate-flipping
  // quirk to correct for the way Board.tsx's draw()/flip has to. See
  // Board.tsx's identical REVEAL_START_MS/REVEAL_STEP_MS/LANDING_MS for why
  // these three numbers -- kept in sync by hand rather than imported, since
  // pulling constants out of one screen's component file into another's
  // is a stranger coupling than three duplicated numbers with a comment.
  const revealStarted = useRef(false)
  const rosterNow = useRef(roster)
  rosterNow.current = roster
  const [revealDelays, setRevealDelays] = useState<Map<string, number>>(new Map())
  const [revealing, setRevealing] = useState(false)

  // Drops ONE card's own reveal delay -- idempotent (a card already gone
  // from the map is left alone), since this is called from two places that
  // can both eventually fire for the same card: `RosterTile`'s own
  // `onAnimationEnd`, and the plain timer just below that exists only to
  // catch the card if that event never comes (reduced motion sets this
  // card's own animation to `none`, which never fires an `animationend` at
  // all -- see the effect's own comment).
  const onTileLanded = useCallback((id: string) => {
    setRevealDelays((prev) => {
      if (!prev.has(id)) return prev
      const next = new Map(prev)
      next.delete(id)
      return next
    })
  }, [])

  useEffect(() => {
    if (revealStarted.current || roster.length === 0) return
    revealStarted.current = true
    const timers: ReturnType<typeof setTimeout>[] = []
    const id = setTimeout(() => {
      setRevealing(true)
      const order = rosterNow.current
      const delays = new Map(order.map((c, i) => [c.id, i * KINGDOM_REVEAL_STEP_MS]))
      setRevealDelays(delays)
      // Used to also set a SECOND timer here, keyed to the LAST tile's own
      // finish time, that cleared every tile's delay AT ONCE -- Jared:
      // "when all cards have been put in the roster, for some reason they
      // all suddenly move a little to the left." Confirmed with a
      // Playwright reproduction of this exact reveal (real timings, real
      // `rtile-land` keyframes, real DOM): while `.is-landing` is still
      // attached, `getComputedStyle(tile).transform` and the tile's actual
      // `getBoundingClientRect().left` can DISAGREE with the plain resting
      // `.rtile` state -- 18px vs 3px in the reproduction, same computed
      // transform STRING, different rendered position -- for as long as
      // the class stays on, which for an early tile (delay 0) was up to
      // ~900ms of sitting rendered ~15px right of where it belongs before
      // the group timer finally caught up and every tile snapped left at
      // once. That gap is what read as "the whole roster suddenly moves."
      //
      // `RosterTile`'s own `onAnimationEnd` now removes THIS card's delay
      // the instant ITS OWN animation genuinely ends (the browser's real
      // completion signal, not a second JS timer estimating it) --
      // confirmed in the same reproduction that dropping the class that
      // way lands each tile within a single frame of its own landing
      // motion finishing, with nothing left to later snap. The per-card
      // timer below is only a SAFETY NET for the one real case that event
      // never fires: `.rtile.is-landing`'s animation is itself switched to
      // `none` under reduced motion, which never dispatches an
      // `animationend` at all -- without this, that card's delay (and the
      // `--reveal-*` custom properties it's still carrying) would simply
      // never clear. `onTileLanded` is idempotent, so a card whose event
      // already fired just no-ops here.
      for (const [i, c] of order.entries()) {
        timers.push(setTimeout(
          () => onTileLanded(c.id),
          i * KINGDOM_REVEAL_STEP_MS + KINGDOM_LANDING_MS + 80,
        ))
      }
    }, KINGDOM_REVEAL_START_MS)
    return () => { clearTimeout(id); timers.forEach(clearTimeout) }
  }, [roster.length > 0, onTileLanded])

  // An account with nothing saved starts on a blank one rather than on an
  // empty screen with a + in the corner: the first thing anybody does here is
  // pick five cards, and making them ask for a box to put them in first is a
  // step that exists only because the data model has one.
  const [list, setList] = useState<Kingdom[]>(() => {
    const ks = profile.kingdoms ?? []
    return ks.length ? ks : [blank()]
  })
  const [selected, setSelected] = useState<string | null>(profile.kingdom ?? null)
  const [openId, setOpenId] = useState<string>(() => {
    const ks = profile.kingdoms ?? []
    return (ks.find((k) => k.id === profile.kingdom) ?? ks[0])?.id ?? ''
  })
  // What the server has confirmed, per kingdom. Seeded from the profile so
  // opening the page does not re-save ten unchanged kingdoms.
  const [saved, setSaved] = useState<Record<string, string>>(() =>
    Object.fromEntries((profile.kingdoms ?? []).map((k) => [k.id, keyOf(k)])))
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [confirming, setConfirming] = useState<Kingdom | null>(null)
  // Item 8: the same long-press-to-inspect behaviour Board.tsx gives a
  // battle unit, here for a roster card instead. Holds a slug, not a
  // boolean, so which card is open survives a re-render the same way
  // Match.tsx's own `peeked` does.
  const [peeked, setPeeked] = useState<string | null>(null)

  const open = list.find((k) => k.id === openId) ?? list[0] ?? null
  useEffect(() => { if (open && open.id !== openId) setOpenId(open.id) }, [open, openId])

  const edit = useCallback((patch: Partial<Kingdom>) => {
    setErr(null)
    setList((l) => l.map((k) => (k.id === openId ? { ...k, ...patch } : k)))
  }, [openId])

  // A card retired since somebody picked it is dropped here the same way
  // cn_clean_kingdoms drops it on the way in, so the count under the grid is
  // the count the server would agree with rather than one that includes a
  // card with no picture.
  useEffect(() => {
    if (!roster.length) return
    setList((l) => {
      const next = l.map((k) => {
        const deck = cleanDeck(k.deck, cards)
        return deck.length === k.deck.length ? k : { ...k, deck }
      })
      return next.some((k, i) => k !== l[i]) ? next : l
    })
  }, [roster.length, cards])

  // ---- saving --------------------------------------------------------------
  useEffect(() => {
    if (!open) return
    const key = keyOf(open)
    if (saved[open.id] === key || isBlank(open)) return
    // deck_of()'s own rule, checked before the round trip rather than after:
    // five cards, all real, exactly one crown, or this kingdom just stays
    // "unsaved" (the savemark under the grid already says so) instead of
    // landing on the server as a row nothing can ever field. Gated on the
    // roster actually being loaded -- with an empty `cards` map every slug
    // would misread as "retired", and there is no picking a card to trip
    // this effect at all before the roster this page renders from has
    // arrived.
    if (roster.length && notFieldable(open.deck, cards)) return
    const { id, name, icon, deck } = open
    const timer = window.setTimeout(() => {
      setSaving(true); setErr(null)
      saveKingdom(id, name, icon, deck)
        .then((ks) => {
          setSaved((s) => ({ ...s, [id]: key }))
          onProfile({ kingdoms: ks })
        })
        .catch((e) => setErr((e as Error).message))
        .finally(() => setSaving(false))
    }, SAVE_MS)
    return () => window.clearTimeout(timer)
  }, [open, saved, onProfile, roster.length, cards])

  // Every kingdom the server has not confirmed yet, blank ones excluded --
  // an untouched blank slot is not "unsaved", it is nothing. This is
  // deliberately broader than `open` alone: switching to a different
  // kingdom before SAVE_MS elapses (see the effect above) clears its timer
  // in the cleanup without ever firing it, which used to mean a quick
  // switch could silently drop an edit -- the Save button below is the
  // fix, and it has to cover every kingdom on the shelf, not just whichever
  // one happens to be open, or it would miss exactly the case it exists for.
  const dirty = list.filter((k) => !isBlank(k) && saved[k.id] !== keyOf(k))
  useEffect(() => { onDirtyChange?.(dirty.length > 0) }, [dirty.length, onDirtyChange])

  // Popped instead of the plain inline `err` line below, so a rule of the
  // game reads like one instead of like a server error message -- per
  // Jared: "always use pop-ups for absolutely everything you want to ask
  // the [user] or warn the user". Holds WHICH of notFieldable's reasons is
  // in the way, because "pick five cards" and "only one crown allowed" are
  // different sentences.
  //
  // This -- and the matching guard in the autosave effect above -- is a
  // deliberate reversal of 0024's own design, which shouted "AN INCOMPLETE
  // KINGDOM IS LEGAL, AND THAT IS THE WHOLE DESIGN" and meant it: the split
  // between a permissive save and a strict deck_of() was built specifically
  // so leaving mid-build never lost progress. Asked directly, Jared chose
  // to give that up in exchange for never being able to save (or walk away
  // from) a kingdom that is not yet a real one -- see project_status.md's
  // entry for this change for the actual question and answer. A half-built
  // kingdom is dirty, stays dirty, and is never written until it is five
  // cards and one crown; closing the tab on one now costs the picks made so
  // far, the same way it would if you never picked them at all.
  const [saveBlocked, setSaveBlocked] = useState<Unready | null>(null)

  async function saveAll() {
    setErr(null)
    if (!dirty.length) return
    // Checked across every kingdom this is about to save, not only the one
    // open -- the same reason `dirty` itself looks past `open` above: the
    // point of one Save for the whole shelf is that a problem in kingdom 2
    // does not get to hide behind kingdom 1 being fine.
    const blocker = dirty.map((k) => notFieldable(k.deck, cards)).find((w) => w !== null)
    if (blocker) {
      setSaveBlocked(blocker)
      return
    }
    setSaving(true)
    try {
      // One at a time, not Promise.all: saveKingdom hands back the WHOLE
      // kingdoms list every time, and onProfile's copy of it has to be
      // built up in order or the second write's response would stomp the
      // first one's out of `profile.kingdoms` on the way past.
      for (const k of dirty) {
        const key = keyOf(k)
        const ks = await saveKingdom(k.id, k.name, k.icon, k.deck)
        setSaved((s) => ({ ...s, [k.id]: key }))
        onProfile({ kingdoms: ks })
      }
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  // ---- and fielding, which follows from it ---------------------------------
  // Gated on the save having landed: select_kingdom on an id the server has
  // never seen lands on the first kingdom instead, because the trigger repoints
  // a selection that points at nothing.
  useEffect(() => {
    if (!open || selected === open.id || !roster.length) return
    if (saved[open.id] !== keyOf(open)) return
    if (!fieldable(open.deck, cards)) return
    let alive = true
    selectKingdom(open.id)
      .then((id) => { if (alive) { setSelected(id); onProfile({ kingdom: id }) } })
      .catch((e) => { if (alive) setErr((e as Error).message) })
    return () => { alive = false }
  }, [open, selected, saved, cards, roster.length, onProfile])

  // ---- the doors -----------------------------------------------------------
  function addKingdom() {
    if (list.length >= KINGDOM_CAP) return
    const k = blank()
    setErr(null)
    setList((l) => [...l, k])
    setOpenId(k.id)
  }

  function toggleCard(slug: string) {
    if (!open) return
    const has = open.deck.includes(slug)
    const deck = has ? open.deck.filter((s) => s !== slug)
      : open.deck.length >= DECK_SIZE ? open.deck
      : [...open.deck, slug]
    if (deck === open.deck) return
    // The mark follows the first card in until somebody picks one on purpose,
    // and a mark whose card has just been taken out stops being a mark.
    const icon = open.icon && deck.includes(open.icon) ? open.icon : deck[0] ?? null
    edit({ deck, icon })
  }

  async function reallyDelete(k: Kingdom) {
    setConfirming(null)
    setList((l) => {
      const next = l.filter((x) => x.id !== k.id)
      return next.length ? next : [blank()]
    })
    setSaved((s) => { const n = { ...s }; delete n[k.id]; return n })
    // A kingdom that was never saved has nothing to delete.
    if (!(k.id in saved)) return
    try {
      const ks = await deleteKingdom(k.id)
      onProfile({ kingdoms: ks })
      // The server repoints a dangling selection; find out where it landed
      // rather than guessing, because guessing wrong means this page and the
      // match disagree about which army is yours.
      if (selected === k.id) {
        const id = await selectKingdom(ks[0]?.id ?? '')
        setSelected(id); onProfile({ kingdom: id })
      }
    } catch (e) { setErr((e as Error).message) }
  }

  // ---- words ---------------------------------------------------------------
  const nameOf = useCallback(
    (k: Kingdom, i: number) => k.name || t('kingdom.untitled', { n: i + 1 }),
    [t],
  )
  const fielded = list.find((k) => k.id === selected) ?? null
  const fieldedIndex = fielded ? list.indexOf(fielded) : -1
  const openIndex = open ? list.indexOf(open) : -1
  const why = open && roster.length ? notFieldable(open.deck, cards) : null

  return (
    <div className="kingwrap">
      {/* ---- the upper side: one button for every kingdom on the shelf ---- */}
      <div className="kingtop">
        <button
          type="button" className="btn primary small"
          disabled={!dirty.length || saving}
          onClick={() => void saveAll()}
        >
          {t('kingdom.save')}
        </button>
        <span className={`savemark${saving ? ' is-busy' : ''}`}>
          {saving ? t('common.saving') : dirty.length ? t('kingdom.unsaved') : t('common.saved')}
        </span>
      </div>

      {/* ---- the shelf ---------------------------------------------------- */}
      <div className="kshelf">
        {list.map((k, i) => {
          return (
            <button
              key={k.id} type="button"
              className={`kchip${k.id === openId ? ' is-open' : ''}` +
                         `${k.id === selected ? ' is-fielded' : ''}`}
              aria-pressed={k.id === openId}
              onClick={() => { setErr(null); setOpenId(k.id) }}
            >
              <Avatar slug={kingdomIcon(k)} name={nameOf(k, i)} size={34} />
              <span className="kchip-text">
                <span className="kchip-name">{nameOf(k, i)}</span>
                {/* Jared: drop the separate "Ready" state -- a kingdom
                    either IS the one you take into a match, or it is not,
                    and the chosen-count already says everything else there
                    is to say about one that is not. */}
                <span className="kchip-note">
                  {k.id === selected ? t('kingdom.fielded')
                   : t('kingdom.chosen', { n: k.deck.length, max: DECK_SIZE })}
                </span>
              </span>
            </button>
          )
        })}
        {list.length < KINGDOM_CAP && (
          <button type="button" className="kchip is-new" onClick={addKingdom}>
            <span className="kchip-plus" aria-hidden="true">+</span>
            <span className="kchip-text">
              <span className="kchip-name">{t('kingdom.new')}</span>
              <span className="kchip-note">
                {t('kingdom.slotsLeft', { n: KINGDOM_CAP - list.length })}
              </span>
            </span>
          </button>
        )}
      </div>

      {open && (
        <>
          {/* ---- its name and its mark ----------------------------------- */}
          <div className="kedit">
            <input
              key={open.id}
              className="kname" type="text" maxLength={KINGDOM_NAME_MAX}
              defaultValue={open.name ?? ''}
              placeholder={t('kingdom.untitled', { n: openIndex + 1 })}
              aria-label={t('kingdom.nameLabel')}
              onChange={(e) => edit({ name: e.target.value.trim() ? e.target.value : null })}
            />
            {/* The mark is chosen from the cards that are IN it, which is the
                only list that can be offered before anything is picked and the
                only one where every answer means something. */}
            <div className="kmarks" role="group" aria-label={t('kingdom.markLabel')}>
              {open.deck.map((slug) => (
                <button
                  key={slug} type="button"
                  className={`kmark${kingdomIcon(open) === slug ? ' is-on' : ''}`}
                  aria-pressed={kingdomIcon(open) === slug}
                  title={t('kingdom.markLabel')}
                  onClick={() => edit({ icon: slug })}
                >
                  <Avatar slug={slug} name={cards.get(slug)?.name ?? '?'} size={26} />
                </button>
              ))}
            </div>
            <button
              type="button" className="btn ghost small kdelete"
              onClick={() => setConfirming(open)}
            >
              {t('kingdom.delete')}
            </button>
          </div>

          {/* ---- the roster, edge to edge -------------------------------- */}
          {/* Jared: "I can't look for a specific class or type a name" --
              search/class NARROW the grid (a card that doesn't match is
              gone, not just moved), which is the actual answer to "find
              Mako" or "find my rogues". Jared, right after: "a sorter
              thing to find cards by class, HP, attack, movement, range
              (ascending and descending), and even by name" -- sort/dir
              only REORDER what is already showing, a different, still-
              useful thing (browse everyone by name without hiding
              anyone). Four separate controls, but one job between them
              ("which cards, in what order") -- Jared: "this looks a
              little crowded, let's simplify" -- so they now share one
              row (.rostertools) instead of two stacked full-width ones,
              wrapping onto a second line on a narrow phone rather than
              needing a breakpoint of its own. One select plus one
              direction toggle rather than six separate ascending/
              descending pairs -- the direction is the same question
              ("which end first?") no matter which stat was picked, so it
              is only asked once, and only shown once there is an actual
              order to reverse. */}
          <div className="rostertools">
            <input
              type="text" className="rostertools-search"
              value={search} onChange={(e) => setSearch(e.target.value)}
              placeholder={t('kingdom.searchPlaceholder')}
              aria-label={t('kingdom.searchPlaceholder')}
            />
            <select
              className="rostertools-select"
              value={classFilter}
              onChange={(e) => setClassFilter(e.target.value)}
              aria-label={t('kingdom.classFilterLabel')}
            >
              <option value="all">{t('kingdom.classFilterAll')}</option>
              {classOptions.map((role) => (
                <option key={role} value={role}>{className(role)}</option>
              ))}
            </select>
            <select
              className="rostertools-select"
              value={sortField}
              onChange={(e) => setSortField(e.target.value as SortField)}
              aria-label={t('kingdom.sortLabel')}
            >
              <option value="none">{t('kingdom.sortNone')}</option>
              <option value="name">{t('kingdom.sortName')}</option>
              <option value="class">{t('kingdom.sortClass')}</option>
              <option value="hp">{t('kingdom.sortHp')}</option>
              <option value="atk">{t('kingdom.sortAtk')}</option>
              <option value="mov">{t('kingdom.sortMov')}</option>
              <option value="range">{t('kingdom.sortRange')}</option>
            </select>
            {sortField !== 'none' && (
              <button
                type="button" className="rostertools-dir"
                onClick={() => setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'))}
                aria-label={sortDir === 'asc' ? t('kingdom.sortAsc') : t('kingdom.sortDesc')}
                title={sortDir === 'asc' ? t('kingdom.sortAsc') : t('kingdom.sortDesc')}
              >
                {sortDir === 'asc' ? '↑' : '↓'}
              </button>
            )}
          </div>
          {visibleRoster.length === 0 && (
            <p className="rosterempty">{t('kingdom.searchEmpty')}</p>
          )}
          <div className="roster-grid">
            {visibleRoster.map((c) => (
              <RosterTile
                key={c.id}
                card={c}
                picked={open.deck.includes(c.slug)}
                pickIndex={open.deck.indexOf(c.slug)}
                full={open.deck.length >= DECK_SIZE}
                onToggle={() => toggleCard(c.slug)}
                onPeek={() => setPeeked(c.slug)}
                // Jared: the is-picked gradient "smoothly and temporarily
                // disappears if you hover or long-press to see this card's
                // ability" -- hover is a plain :hover rule (see .rtile::after
                // in styles.css), but the long-press's own card is a whole
                // separate overlay elsewhere on the page (`peeked`, below),
                // not something `.rtile-info`'s own hover machinery ever
                // sees, so THIS tile has no other way to learn its card is
                // the one being read. peeking threads that one bit down.
                peeking={peeked === c.slug}
                revealDelayMs={revealDelays.get(c.id)}
                prereveal={!revealDelays.has(c.id) && !revealing}
                onLanded={() => onTileLanded(c.id)}
              />
            ))}
          </div>

          {/* Item 8: the peeked card, phone-only (bigcard-peek/.peekscrim are
              already hidden above the hover/pointer breakpoint) -- see
              Match.tsx's identical pairing for the battle version of this.
              Jared: the card opens "randomly vertically" instead of dead
              centre -- .bigcard-peek is `position: fixed; top: 50%`, which
              should already centre it on the viewport regardless of scroll,
              but this page's own roster scrolls INSIDE `.page-body`
              (`overflow-y: auto`), and a `position: fixed` element mounted
              inside an actively-scrolling ancestor is a well-known WebKit
              bug on iOS specifically: Safari can paint it at the scroll
              offset that was current when it last settled rather than the
              viewport's true centre, which reads as "shows up somewhere
              random" the more you've scrolled. Match.tsx's own board never
              scrolls at all, so its identical pairing never hits this.
              Fixed the same way §61 fixed the Duel cinematic for the exact
              same reason: a portal to document.body takes it out of the
              scrolling subtree entirely, so there is no longer an
              ancestor's scroll position for Safari to get wrong -- it sits
              directly under the real viewport, the one `position: fixed`
              was always supposed to mean. */}
          {peeked && createPortal(
            <>
              <div className="peekscrim" onPointerDown={() => setPeeked(null)} aria-hidden="true" />
              {(() => {
                const c = cards.get(peeked)
                return c ? <CardBigCard card={c} side="peek" /> : null
              })()}
            </>,
            document.body,
          )}

          {/* ---- what it is, and what you are actually taking in --------- */}
          <div className="deckfoot">
            <span className="muted tiny">
              {t('kingdom.chosen', { n: open.deck.length, max: DECK_SIZE })}
              {why && ` — ${unreadyText(why, open.deck, t)}`}
            </span>
            <span className={`savemark${saving ? ' is-busy' : ''}`}>
              {saving ? t('common.saving')
               : saved[open.id] === keyOf(open) ? t('common.saved')
               : ''}
            </span>
          </div>
          <p className="muted tiny fieldingnote">
            {fielded && roster.length > 0 && fieldable(fielded.deck, cards)
              ? t('kingdom.fielding', { name: nameOf(fielded, fieldedIndex) })
              : t('kingdom.fieldingDefault')}
          </p>
        </>
      )}

      {err && <p className="error">{err}</p>}

      {confirming && (
        <Modal
          title={t('kingdom.deleteTitle', { name: nameOf(confirming, list.indexOf(confirming)) })}
          onClose={() => setConfirming(null)}
        >
          <p className="muted">{t('kingdom.deleteBody')}</p>
          <div className="actionbar">
            <button className="btn ghost" onClick={() => setConfirming(null)}>
              {t('common.cancel')}
            </button>
            <button className="btn danger" onClick={() => void reallyDelete(confirming)}>
              {t('kingdom.deleteYes')}
            </button>
          </div>
        </Modal>
      )}

      {/* Info, not a confirm -- there is nothing to choose between, only
          something to go fix, so one OK rather than a Cancel/Yes pair. One
          title per reason (SAVE_BLOCKED_TITLE below): "pick five cards" and
          "only one crown allowed" are not the same sentence, and showing the
          crown one for a deck that is simply short would send somebody
          looking for a second card to swap instead of four more to add.
          `hasRetired` has no title of its own -- the roster-cleanup effect
          above already drops a retired card from every deck before this can
          ever run, so notFieldable finding one here would mean that effect
          itself broke, not something a player did; it borrows tooFew's
          title as the least-wrong fallback rather than getting a fourth
          string for a case that should be unreachable. */}
      {saveBlocked && (
        <Modal title={t(SAVE_BLOCKED_TITLE[saveBlocked])} onClose={() => setSaveBlocked(null)}>
          <div className="actionbar">
            <button className="btn primary" onClick={() => setSaveBlocked(null)}>
              {t('common.ok')}
            </button>
          </div>
        </Modal>
      )}
    </div>
  )
}

/**
 * One roster tile. Its own component, not inlined in the `roster.map` above,
 * because useLongPress is a hook and a hook cannot be called from inside a
 * loop -- the same reason Board.tsx's per-unit long press lives on its own
 * `Thing`/unit component rather than inline in the board that maps over them.
 *
 * `.rtile-info` already reveals this card's stats on hover for a mouse; the
 * long press is additive, for the pointer that has no hover -- useLongPress
 * itself is a no-op for anything that isn't a touch pointer, so nothing here
 * changes for a trackpad or a mouse.
 */
function RosterTile({
  card: c, picked, pickIndex, full, onToggle, onPeek, peeking, revealDelayMs, prereveal, onLanded,
}: {
  card: Card
  picked: boolean
  /** open.deck.indexOf(c.slug) -- -1 when not picked, ignored in that case. */
  pickIndex: number
  full: boolean
  onToggle: () => void
  onPeek: () => void
  /** True while THIS card's own long-press overlay is open -- see the
   *  gradient's own comment where this is passed down. */
  peeking?: boolean
  /** This tile's own stagger offset, in ms, WHILE its landing animation is
   *  actually playing -- undefined the rest of the time (before its turn,
   *  same as `prereveal` below, and forever after it has settled). See the
   *  screen's own reveal effect above. */
  revealDelayMs?: number
  /** True from this tile's very first render until the screen's one-shot
   *  reveal actually reaches it -- a plain, unconditional hide so there is
   *  nothing to see before the animation, rather than a pop-then-hide (see
   *  Board.tsx's identical .unit-slot.is-prereveal fix). */
  prereveal?: boolean
  /** Fired once, from `onAnimationEnd` below, the instant THIS tile's own
   *  `rtile-land` genuinely finishes -- the screen's cue to drop this
   *  card's own reveal delay right then, rather than on a second timer
   *  keyed to the LAST card. See the reveal effect's own comment on why a
   *  shared timer read as "the whole roster suddenly moves a little to
   *  the left." */
  onLanded?: () => void
}) {
  const t = useT()
  const className = useClassName()
  const press = useLongPress(onPeek)
  return (
    <button
      type="button" aria-pressed={picked}
      aria-label={t('team.cardLabel', { name: c.name, role: className(c.role) })}
      className={`rtile${picked ? ' is-picked' : ''}${!picked && full ? ' is-spare' : ''}` +
                 `${c.role ? ` role-${c.role}` : ''}` +
                 `${revealDelayMs != null ? ' is-landing' : ''}${prereveal ? ' is-prereveal' : ''}` +
                 `${peeking ? ' is-peeking' : ''}`}
      style={{
        '--accent': c.accent,
        ...(revealDelayMs != null
          ? {
              '--landing-ms': `${KINGDOM_LANDING_MS}ms`,
              '--reveal-delay': `${revealDelayMs}ms`,
              // The real fix for the opacity "snap" Jared kept seeing after
              // two earlier attempts that both looked right on paper (and
              // even tested right in isolation) and still did nothing:
              // `.rtile.is-landing`'s own CSS ANIMATION was ending and
              // handing off to `.is-spare`'s plain `opacity: 0.3` in the
              // SAME class swap, and a CSS TRANSITION does not fire on a
              // value change caused by an animation ending like that --
              // there is no "before" value for it to animate from, no
              // matter what is in `.rtile`'s own `transition` list.
              // Confirmed this empirically (a Playwright repro of exactly
              // this handoff sampled the computed opacity 20ms after the
              // swap and found it already at 0.3 -- an instant jump, every
              // time) rather than trusting the reasoning alone a third
              // time. Fixed at the root instead of chasing the handoff: the
              // landing keyframe's OWN 100% step now ends at this card's
              // real resting opacity, so by the time `is-landing` comes off,
              // the value has ALREADY arrived there smoothly, as part of
              // the landing animation itself -- there is no leftover jump
              // for a transition to fail to catch, because nothing changes
              // at the handoff moment at all.
              '--landing-end-opacity': String(!picked && full ? 0.3 : 1),
            }
          : {}),
      } as React.CSSProperties}
      {...press.handlers}
      onClick={(e) => { if (press.swallowed()) { e.stopPropagation(); return } onToggle() }}
      onAnimationEnd={(e) => { if (e.animationName === 'rtile-land') onLanded?.() }}
    >
      <span
        className="rtile-art"
        style={{ backgroundImage: `url(${artUrl(c.art_url) ?? ''})` }}
        aria-hidden="true"
      />
      {picked && <span className="rtile-pick">{pickIndex + 1}</span>}
      <span className="rtile-name">{c.name}</span>

      <span className="rtile-info">
        <span className="rti-head">
          <b>{c.name}</b>
          {c.role && <em>{className(c.role)}</em>}
        </span>
        {/* No CTR row any more -- Jared: "cards have a CTR number, I have
            no idea what that is... let's completely remove it from
            everywhere." It was never a second, independently-tunable stat:
            AdminCards.tsx's own comment on its single "Range" box says why
            -- "since 0030 `range` is the only reach number anybody sets...
            the trigger derives rmin/rmax/crmin/crmax from it on the way
            in." crmin/crmax are already, by construction, always identical
            to rmin/rmax for every card, which is exactly "range decides
            both attack and counter-attack" -- what Jared confirmed he
            wanted when asked whether this was display-only or a real rules
            change. Nothing about combat needed touching, only this row,
            which was showing a number that could never differ from RNG
            right above it and had no way to explain itself. */}
        <span className="rti-stats">
          <span><i>{t('stat.hp')}</i><b>{c.hp}</b></span>
          <span><i>{t(c.heals ? 'stat.pwr' : 'stat.dmg')}</i><b>{unitPower(c)}</b></span>
          <span><i>{t('stat.mov')}</i><b>{c.mov}</b></span>
          <span><i>{t('stat.rng')}</i><b>{reachText(c.rmin, c.rmax)}</b></span>
        </span>
        <Ability className="rti-ability" text={abilityText(c)} plain />
        <span className="rti-cta">
          {t(picked ? 'team.remove' : full ? 'team.full' : 'team.add')}
        </span>
      </span>
    </button>
  )
}
