import { useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useMenuSections } from '../lib/useMenuSections'
import { useContentOverrides } from '../lib/useContentOverrides'
import type { ContentOverride, MenuSection } from '../lib/types'
import en from '../i18n/en.json'
// 0087's crop controls preview each tile with its OWN real art and its own
// hand-tuned default position -- TILES/hBias are Lobby.tsx's own source of
// truth for both, reused here rather than a second copy that could drift.
import { hBias, TILES } from './Lobby'

/** English labels for the lobby's own tile ids -- see TILES in Lobby.tsx.
 *  Not read from the dictionary: this screen is Admin Mode, and Admin Mode
 *  does not go through t() any more than AdminCards does. */
const TILE_LABELS: Record<string, string> = {
  play: 'Play', ranked: 'Ranked', bot: 'Practice', friends: 'Friends', spectate: 'Watch',
  ladder: 'Ladder', team: 'My Kingdom', tournament: 'Tournament', comics: 'Comics',
}

/** Every top-level key in the bundled English dictionary -- there is no
 *  nesting, so this is every string t() can render. Used to build the "new
 *  override" field's suggestions: an admin typing a key gets to see what
 *  actually exists rather than guessing at one. */
const EN_KEYS = Object.keys(en as Record<string, string>).sort()

type BilingualField = 'title_en' | 'title_es' | 'subtitle_en' | 'subtitle_es'
type ArtField = 'art_x' | 'art_y' | 'art_zoom'

/** hBias()/`focus` are stored as literal CSS strings ('58%', 'center') --
 *  this screen's sliders need plain 0-100 numbers to start from, same scale,
 *  so a tile nobody has touched from Admin Mode shows its slider sitting
 *  exactly where that tile already renders today rather than at a false 50. */
function pct(v: string): number {
  if (v === 'center') return 50
  const n = parseFloat(v)
  return Number.isFinite(n) ? n : 50
}

/**
 * Live Menu Manager. Every tile row here is a `menu_sections` row (0042);
 * Lobby.tsx folds visible/sort over its own TILES constant, which is where
 * the colour, the picture and the focus point still live -- this screen
 * only ever decides whether a tile is shown, where it sits, and (since
 * 0046) what its headline and note say.
 *
 * Two tabs, because the two things this screen edits are shaped differently:
 * the eight tiles are a fixed, known list (rows this table has always had),
 * while content overrides are an open-ended set an admin builds up one
 * string at a time. See 0046_admin_content_and_delete.sql's header comment
 * for the fuller reasoning behind the second mechanism.
 */
export function AdminMenu() {
  const [subTab, setSubTab] = useState<'tiles' | 'social' | 'overrides'>('tiles')
  return (
    <div className="admin-menu">
      <div className="admin-menusubtabs">
        <button
          type="button" className={`btn small ${subTab === 'tiles' ? 'primary' : 'ghost'}`}
          onClick={() => setSubTab('tiles')}
        >
          Tiles
        </button>
        <button
          type="button" className={`btn small ${subTab === 'social' ? 'primary' : 'ghost'}`}
          onClick={() => setSubTab('social')}
        >
          Social links
        </button>
        <button
          type="button" className={`btn small ${subTab === 'overrides' ? 'primary' : 'ghost'}`}
          onClick={() => setSubTab('overrides')}
        >
          Content overrides
        </button>
      </div>
      {subTab === 'tiles' ? <TilesTab /> : subTab === 'social' ? <SocialLinksTab /> : <OverridesTab />}
    </div>
  )
}

/**
 * Jared: "make it so that I can edit the discord and instagram link from
 * the admin mode." Both were already editable, technically -- Lobby.tsx's
 * footer has read them through `t('lobby.discordUrl')`/`t('lobby.instagramUrl')`
 * since 0046, and the generic Content overrides tab below can already
 * rewrite any key including those two. That generic form is real but not
 * obvious (an admin has to already know, or guess from the datalist, the
 * exact key), and it has one sharp edge for a URL specifically: it keeps
 * separate English/Spanish boxes, and a URL has nothing to translate -- an
 * admin who fills only the English box leaves `value_es` as an empty
 * STRING, not absent, and `translate()`'s `??` fallback chain does not
 * treat '' as "keep looking", so a Spanish reader would get a dead `href`
 * rather than the site's own link. This tab is the two keys that actually
 * exist, written to both language columns at once so that edge case can't
 * happen here, plus a Reset that's one click instead of the confirm
 * dialog the generic tab needs (a URL has no history worth guarding).
 */
const SOCIAL_LINKS: { key: string; label: string }[] = [
  { key: 'lobby.discordUrl', label: 'Discord' },
  { key: 'lobby.instagramUrl', label: 'Instagram' },
]

function SocialLinksTab() {
  const overrides = useContentOverrides()
  const byKey = useMemo(
    () => Object.fromEntries(overrides.map((o) => [o.key, o])),
    [overrides],
  )
  const [busyKey, setBusyKey] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  async function save(key: string, value: string) {
    setBusyKey(key); setErr(null); setNote(null)
    const { error } = await supabase
      .from('menu_content_overrides')
      .upsert({ key, value_en: value, value_es: value })
    setBusyKey(null)
    if (error) { setErr(error.message.replace(/^.*?:\s*/, '')); return }
    setNote('Saved.')
  }

  async function reset(key: string) {
    setBusyKey(key); setErr(null); setNote(null)
    const { error } = await supabase.from('menu_content_overrides').delete().eq('key', key)
    setBusyKey(null)
    if (error) { setErr(error.message); return }
    setNote('Back to the default link.')
  }

  return (
    <div className="admin-menu-tiles">
      <p className="muted tiny admin-wide">
        Where the two footer icons at the bottom of the main menu send a
        player, for every signed-in player in either language at once -- a
        link has nothing to translate. No deploy, and it takes effect the
        moment you leave the box. Leave one blank and Save to fall back to
        the game's own address instead of an empty link.
      </p>
      <ul className="admin-sectionlist">
        {SOCIAL_LINKS.map(({ key, label }) => {
          const override = byKey[key]
          const fallback = (en as Record<string, string>)[key] ?? ''
          const current = override?.value_en ?? fallback
          return (
            <li key={key}>
              <div className="admin-sectionrow">
                <span className="admin-rowname">{label}</span>
              </div>
              <label className="admin-sectionfield">
                <span>URL</span>
                <input
                  key={`${key}-${current}`}
                  defaultValue={current}
                  disabled={busyKey === key}
                  placeholder={fallback}
                  onBlur={(e) => {
                    const v = e.target.value.trim()
                    if (!v) { void save(key, fallback); return }
                    if (v !== current) void save(key, v)
                  }}
                />
              </label>
              <button
                type="button" className="btn tiny ghost"
                disabled={busyKey === key || !override}
                onClick={() => void reset(key)}
              >
                Reset to default
              </button>
            </li>
          )
        })}
      </ul>
      {note && <p className="tiny savemark">{note}</p>}
      {err && <p className="error tiny">{err}</p>}
    </div>
  )
}

function TilesTab() {
  const sections = useMenuSections()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  const ordered = sections.slice().sort((a, b) => a.sort - b.sort)

  async function toggleVisible(id: string, visible: boolean) {
    setErr(null)
    const { error } = await supabase.from('menu_sections').update({ visible }).eq('id', id)
    if (error) setErr(error.message)
  }

  async function move(id: string, dir: -1 | 1) {
    const idx = ordered.findIndex((s) => s.id === id)
    const a = ordered[idx]
    const swap = ordered[idx + dir]
    if (!a || !swap) return
    setBusy(true); setErr(null)
    const { error: e1 } = await supabase.from('menu_sections').update({ sort: swap.sort }).eq('id', a.id)
    const { error: e2 } = await supabase.from('menu_sections').update({ sort: a.sort }).eq('id', swap.id)
    setBusy(false)
    if (e1 || e2) setErr((e1 ?? e2)?.message ?? 'could not reorder')
  }

  // Since 0046: writes straight to the row's own title_en/title_es/
  // subtitle_en/subtitle_es. A blank box is the same as never having typed
  // anything -- the touch trigger nulls an empty string on the way in -- so
  // there is nothing special to do here to "clear" one; typing nothing and
  // leaving the field does it.
  async function commitField(id: string, field: BilingualField, value: string) {
    setErr(null)
    const { error } = await supabase.from('menu_sections').update({ [field]: value }).eq('id', id)
    if (error) setErr(error.message)
  }

  async function resetOverrides(id: string) {
    setErr(null)
    const { error } = await supabase.from('menu_sections')
      .update({ title_en: null, title_es: null, subtitle_en: null, subtitle_es: null })
      .eq('id', id)
    if (error) setErr(error.message)
  }

  // Since 0087: "move the picture... or zooming them or unzooming them."
  // One column at a time, same as toggleVisible above -- a slider release
  // touches only the field it moved, never the other two.
  async function commitArt(id: string, field: ArtField, value: number | null) {
    setErr(null)
    const { error } = await supabase.from('menu_sections').update({ [field]: value }).eq('id', id)
    if (error) setErr(error.message)
  }

  async function resetArt(id: string) {
    setErr(null)
    const { error } = await supabase.from('menu_sections')
      .update({ art_x: null, art_y: null, art_zoom: null })
      .eq('id', id)
    if (error) setErr(error.message)
  }

  return (
    <div className="admin-menu-tiles">
      <p className="muted tiny admin-wide">
        Show, hide or reorder the lobby's tiles, and optionally give one a
        headline or note of your own, in either language. Every signed-in
        player sees the change within a moment of it landing here -- no
        deploy, no refresh. Leave a box blank to use the game's normal words.
      </p>
      <ul className="admin-sectionlist">
        {ordered.map((s, i) => (
          <li key={s.id} className={s.visible ? '' : 'is-retired'}>
            <div className="admin-sectionrow">
              <span className="admin-rowname">{TILE_LABELS[s.id] ?? s.id}</span>
              <span className="admin-trackacts">
                <button
                  type="button" className="btn tiny ghost" disabled={busy || i === 0}
                  onClick={() => void move(s.id, -1)} aria-label="Move earlier"
                >
                  ↑
                </button>
                <button
                  type="button" className="btn tiny ghost" disabled={busy || i === ordered.length - 1}
                  onClick={() => void move(s.id, 1)} aria-label="Move later"
                >
                  ↓
                </button>
                <label className="admin-flag">
                  <input
                    type="checkbox" checked={s.visible} disabled={busy}
                    onChange={(e) => void toggleVisible(s.id, e.target.checked)}
                  />
                  <span>Visible</span>
                </label>
              </span>
            </div>
            <SectionFields
              section={s} onCommit={commitField} onReset={resetOverrides}
              onCommitArt={commitArt} onResetArt={resetArt}
            />
          </li>
        ))}
        {ordered.length === 0 && (
          <li className="muted tiny">
            Nothing here yet -- run 0042_menu_sections.sql in the Supabase SQL Editor.
          </li>
        )}
      </ul>
      {err && <p className="error tiny">{err}</p>}
    </div>
  )
}

/**
 * The four bilingual override boxes for one tile row.
 *
 * Uncontrolled on purpose, each keyed by its own current value: typing does
 * not fight a parent re-render (nothing writes back until blur), and when
 * the stored value actually changes -- this admin's own write coming back
 * over Realtime, another admin's edit, or a Reset -- the key changes with it
 * and React remounts the input with the new value as its fresh starting
 * point, exactly the moment a controlled input would otherwise refuse to
 * update because "the user is still focused here".
 */
function SectionFields({ section, onCommit, onReset, onCommitArt, onResetArt }: {
  section: MenuSection
  onCommit: (id: string, field: BilingualField, value: string) => void
  onReset: (id: string) => void
  onCommitArt: (id: string, field: ArtField, value: number | null) => void
  onResetArt: (id: string) => void
}) {
  const hasOverride = Boolean(
    section.title_en || section.title_es || section.subtitle_en || section.subtitle_es,
  )
  const field = (label: string, key: BilingualField) => (
    <label className="admin-sectionfield">
      <span>{label}</span>
      <input
        key={`${section.id}-${key}-${section[key] ?? ''}`}
        defaultValue={section[key] ?? ''}
        placeholder="(default)"
        onBlur={(e) => {
          if (e.target.value !== (section[key] ?? '')) onCommit(section.id, key, e.target.value)
        }}
      />
    </label>
  )
  return (
    <div className="admin-sectionfields">
      {field('Title (EN)', 'title_en')}
      {field('Title (ES)', 'title_es')}
      {field('Note (EN)', 'subtitle_en')}
      {field('Note (ES)', 'subtitle_es')}
      <button
        type="button" className="btn tiny ghost" disabled={!hasOverride}
        onClick={() => onReset(section.id)}
      >
        Reset to default
      </button>
      <ArtCrop section={section} onCommitArt={onCommitArt} onResetArt={onResetArt} />
    </div>
  )
}

/**
 * "Make it so that I can change the picture and/or crop them as I want,
 * because maybe I want to move them a little to the right, left, up or
 * down. Or zooming them or unzooming them." (Jared)
 *
 * Three sliders over the tile's own real picture, rendered the same way
 * Lobby.tsx's .mtile-art draws it -- background-size: cover, a
 * background-position percentage, and a scale -- so what an admin sees here
 * is what every player will see, not a stand-in. A tile this build doesn't
 * know about (should never happen -- every menu_sections row is seeded from
 * a TILES entry) just gets no preview image behind it; the sliders still work.
 *
 * Range inputs, not the bilingual fields' uncontrolled-and-key-remounted
 * pattern: those commit on blur, which is right for text but wrong here --
 * an admin wants to SEE the crop move as they drag, not just after they let
 * go. `onInput` (fires continuously while dragging) drives the live local
 * preview; `onChange` (fires once, on release) is the only thing that
 * writes to the database, so a drag across the whole slider is still one
 * row update, not sixty.
 */
function ArtCrop({ section, onCommitArt, onResetArt }: {
  section: MenuSection
  onCommitArt: (id: string, field: ArtField, value: number | null) => void
  onResetArt: (id: string) => void
}) {
  const tile = TILES.find((t) => t.id === section.id)
  const defaultX = tile ? pct(hBias(tile.id)) : 50
  const defaultY = tile ? pct(tile.focus) : 50

  const [x, setX] = useState(section.art_x ?? defaultX)
  const [y, setY] = useState(section.art_y ?? defaultY)
  const [zoom, setZoom] = useState(section.art_zoom ?? 100)
  const hasOverride = section.art_x != null || section.art_y != null || section.art_zoom != null

  return (
    <div className="admin-artcrop">
      <div
        className="admin-artpreview"
        style={{ background: tile?.tint ?? '#3f3f56' }}
        aria-hidden="true"
      >
        {tile?.art && (
          <div
            className="admin-artpreview-img"
            style={{
              backgroundImage: `url(${import.meta.env.BASE_URL}${tile.art})`,
              backgroundPosition: `${x}% ${y}%`,
              transform: `scale(${zoom / 100})`,
            }}
          />
        )}
      </div>
      <label className="admin-artslider">
        <span>Left / right ({Math.round(x)}%)</span>
        <input
          type="range" min={0} max={100} step={1}
          key={`${section.id}-x-${section.art_x ?? 'd'}`}
          defaultValue={x}
          onInput={(e) => setX(Number((e.target as HTMLInputElement).value))}
          onChange={(e) => onCommitArt(section.id, 'art_x', Number(e.target.value))}
        />
      </label>
      <label className="admin-artslider">
        <span>Up / down ({Math.round(y)}%)</span>
        <input
          type="range" min={0} max={100} step={1}
          key={`${section.id}-y-${section.art_y ?? 'd'}`}
          defaultValue={y}
          onInput={(e) => setY(Number((e.target as HTMLInputElement).value))}
          onChange={(e) => onCommitArt(section.id, 'art_y', Number(e.target.value))}
        />
      </label>
      <label className="admin-artslider">
        <span>Zoom ({Math.round(zoom)}%)</span>
        <input
          type="range" min={50} max={400} step={5}
          key={`${section.id}-zoom-${section.art_zoom ?? 'd'}`}
          defaultValue={zoom}
          onInput={(e) => setZoom(Number((e.target as HTMLInputElement).value))}
          onChange={(e) => onCommitArt(section.id, 'art_zoom', Number(e.target.value))}
        />
      </label>
      <button
        type="button" className="btn tiny ghost" disabled={!hasOverride}
        onClick={() => {
          onResetArt(section.id)
          setX(defaultX); setY(defaultY); setZoom(100)
        }}
      >
        Reset crop to default
      </button>
    </div>
  )
}

/** A fresh, unsaved override -- the "new" form's shape before it has a key
 *  worth writing under. */
const BLANK_OVERRIDE: ContentOverride = { key: '', value_en: '', value_es: '' }

function OverridesTab() {
  const overrides = useContentOverrides()
  const [query, setQuery] = useState('')
  const [openKey, setOpenKey] = useState<string | null>(null)
  const [draft, setDraft] = useState<ContentOverride | null>(null)
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    const rows = q ? overrides.filter((o) => o.key.toLowerCase().includes(q)) : overrides
    return rows.slice().sort((a, b) => a.key.localeCompare(b.key))
  }, [overrides, query])

  // Substring, not prefix: a <datalist>'s own filtering is prefix-only in
  // some browsers, so the options offered are pre-filtered here to whatever
  // the key box already contains, wherever in the key it appears.
  const keySuggestions = useMemo(() => {
    const q = (draft?.key ?? '').trim().toLowerCase()
    const rows = q ? EN_KEYS.filter((k) => k.toLowerCase().includes(q)) : EN_KEYS
    return rows.slice(0, 40)
  }, [draft?.key])

  function openExisting(o: ContentOverride) {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenKey(o.key); setDraft({ ...o })
  }
  function openNew() {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenKey('new'); setDraft({ ...BLANK_OVERRIDE })
  }

  async function save() {
    if (!draft) return
    const key = draft.key.trim()
    if (!key) { setErr('Give the override a key -- the exact dotted name it overrides, like lobby.ranked.'); return }
    setBusy(true); setErr(null); setNote(null)
    const { error } = await supabase
      .from('menu_content_overrides')
      .upsert({ key, value_en: draft.value_en, value_es: draft.value_es })
    setBusy(false)
    if (error) { setErr(error.message.replace(/^.*?:\s*/, '')); return }
    setNote(`Saved ${key}.`)
    setOpenKey(key); setDraft({ key, value_en: draft.value_en, value_es: draft.value_es })
  }

  async function resetKey(key: string) {
    setBusy(true); setErr(null); setNote(null)
    const { error } = await supabase.from('menu_content_overrides').delete().eq('key', key)
    setBusy(false)
    if (error) { setErr(error.message); return }
    setNote(`${key} is back to its built-in text.`)
    setOpenKey(null); setDraft(null); setConfirmDelete(null)
  }

  return (
    <div className="admin-grid admin-userlayout">
      <div className="admin-list">
        <p className="muted tiny">
          Override the text behind any existing key from the game's dictionary,
          in both languages. Every screen that reads that key through t()
          shows your words instead, everywhere, immediately -- no deploy.
        </p>
        <input
          value={query} onChange={(e) => setQuery(e.target.value)}
          placeholder="Search overrides by key…"
        />
        <button type="button" className="btn small" onClick={openNew}>New override</button>
        {filtered.map((o) => (
          <button
            key={o.key} type="button"
            className={`admin-row${o.key === openKey ? ' is-open' : ''}`}
            onClick={() => openExisting(o)}
          >
            <span className="admin-rowname">{o.key}</span>
          </button>
        ))}
        {filtered.length === 0 && (
          <p className="muted tiny">
            {overrides.length === 0 ? 'No overrides yet.' : `Nothing matches "${query}".`}
          </p>
        )}
      </div>

      {draft && (
        <form className="admin-form" onSubmit={(e) => { e.preventDefault(); void save() }}>
          <label className="admin-wide"><span>i18n key (exact, e.g. lobby.ranked)</span>
            {openKey === 'new' ? (
              <>
                <input
                  value={draft.key} list="admin-override-keys"
                  onChange={(e) => setDraft({ ...draft, key: e.target.value })}
                />
                <datalist id="admin-override-keys">
                  {keySuggestions.map((k) => <option key={k} value={k} />)}
                </datalist>
              </>
            ) : (
              <input value={draft.key} disabled />
            )}
          </label>
          <label className="admin-wide"><span>English</span>
            <textarea
              rows={2} value={draft.value_en}
              onChange={(e) => setDraft({ ...draft, value_en: e.target.value })}
            />
          </label>
          <label className="admin-wide"><span>Spanish</span>
            <textarea
              rows={2} value={draft.value_es}
              onChange={(e) => setDraft({ ...draft, value_es: e.target.value })}
            />
          </label>
          <div className="actionbar admin-acts">
            <button className="btn primary" disabled={busy}>{busy ? 'Saving…' : 'Save'}</button>
            {openKey && openKey !== 'new' && (
              confirmDelete === openKey ? (
                <>
                  <span className="admin-bantext">Really reset {openKey} to its default?</span>
                  <button
                    type="button" className="btn danger small" disabled={busy}
                    onClick={() => void resetKey(openKey)}
                  >
                    Yes
                  </button>
                  <button
                    type="button" className="btn ghost small" disabled={busy}
                    onClick={() => setConfirmDelete(null)}
                  >
                    No
                  </button>
                </>
              ) : (
                <button
                  type="button" className="btn ghost" disabled={busy}
                  onClick={() => setConfirmDelete(openKey)}
                >
                  Reset to default
                </button>
              )
            )}
            {note && <span className="savemark">{note}</span>}
          </div>
          {err && <p className="error admin-wide">{err}</p>}
        </form>
      )}
    </div>
  )
}
