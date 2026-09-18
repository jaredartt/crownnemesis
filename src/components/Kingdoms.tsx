import { useCallback, useEffect, useMemo, useState } from 'react'
import { deleteKingdom, saveKingdom, selectKingdom } from '../lib/api'
import {
  KINGDOM_CAP, KINGDOM_NAME_MAX, cleanDeck, fieldable, isBlank, kingdomIcon,
  newKingdomId, notFieldable, unreadyText,
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

const keyOf = (k: Kingdom) => JSON.stringify([k.name, k.icon, k.deck])
const blank = (): Kingdom => ({ id: newKingdomId(), name: null, icon: null, deck: [] })

export function Kingdoms({ profile, roster, onProfile }: {
  profile: Profile
  roster: Card[]
  onProfile: (patch: Partial<Profile>) => void
}) {
  const t = useT()
  const cards = useMemo(() => new Map(roster.map((c) => [c.slug, c])), [roster])

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
  }, [open, saved, onProfile])

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
      {/* ---- the shelf ---------------------------------------------------- */}
      <div className="kshelf">
        {list.map((k, i) => {
          const ready = roster.length > 0 && fieldable(k.deck, cards)
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
                <span className="kchip-note">
                  {k.id === selected ? t('kingdom.fielded')
                   : ready ? t('kingdom.ready')
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
          <div className="roster-grid">
            {roster.map((c) => (
              <RosterTile
                key={c.id}
                card={c}
                picked={open.deck.includes(c.slug)}
                pickIndex={open.deck.indexOf(c.slug)}
                full={open.deck.length >= DECK_SIZE}
                onToggle={() => toggleCard(c.slug)}
                onPeek={() => setPeeked(c.slug)}
              />
            ))}
          </div>

          {/* Item 8: the peeked card, phone-only (bigcard-peek/.peekscrim are
              already hidden above the hover/pointer breakpoint) -- see
              Match.tsx's identical pairing for the battle version of this. */}
          {peeked && (
            <>
              <div className="peekscrim" onPointerDown={() => setPeeked(null)} aria-hidden="true" />
              {(() => {
                const c = cards.get(peeked)
                return c ? <CardBigCard card={c} side="peek" /> : null
              })()}
            </>
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
function RosterTile({ card: c, picked, pickIndex, full, onToggle, onPeek }: {
  card: Card
  picked: boolean
  /** open.deck.indexOf(c.slug) -- -1 when not picked, ignored in that case. */
  pickIndex: number
  full: boolean
  onToggle: () => void
  onPeek: () => void
}) {
  const t = useT()
  const className = useClassName()
  const press = useLongPress(onPeek)
  return (
    <button
      type="button" aria-pressed={picked}
      aria-label={t('team.cardLabel', { name: c.name, role: className(c.role) })}
      className={`rtile${picked ? ' is-picked' : ''}${!picked && full ? ' is-spare' : ''}`}
      style={{ '--accent': c.accent } as React.CSSProperties}
      {...press.handlers}
      onClick={(e) => { if (press.swallowed()) { e.stopPropagation(); return } onToggle() }}
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
        <span className="rti-stats">
          <span><i>{t('stat.hp')}</i><b>{c.hp}</b></span>
          <span><i>{t(c.heals ? 'stat.pwr' : 'stat.dmg')}</i><b>{unitPower(c)}</b></span>
          <span><i>{t('stat.mov')}</i><b>{c.mov}</b></span>
          <span><i>{t('stat.rng')}</i><b>{reachText(c.rmin, c.rmax)}</b></span>
          <span><i>{t('stat.ctr')}</i><b>{reachText(c.crmin, c.crmax)}</b></span>
        </span>
        <Ability className="rti-ability" text={abilityText(c)} plain />
        <span className="rti-cta">
          {t(picked ? 'team.remove' : full ? 'team.full' : 'team.add')}
        </span>
      </span>
    </button>
  )
}
