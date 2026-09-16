import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { artUrl, faceUrl } from '../lib/art'
import type { Card } from '../lib/types'
import { clearCards } from '../lib/useCards'

/**
 * The card editor. Jared's account only.
 *
 * IN ENGLISH ONLY, ON PURPOSE. Everything else in this app goes through t()
 * and exists in two languages, because everything else is read by players. This
 * is read by one person, who wrote the Spanish. Forty dictionary keys nobody
 * will ever render in the other language is forty things to keep in step for
 * no reader -- so this screen says what it means in plain words and the
 * dictionaries stay the size of the game.
 *
 * THERE IS A SAVE BUTTON HERE, and that is not an inconsistency. My Kingdom
 * saves itself because it is your own team and a mistake costs you one tap to
 * undo. This is the roster every match in the game is built from, and a stray
 * keystroke in a number field should not be live before you have finished
 * typing it.
 *
 * The writes are ordinary table writes. The RLS policy "admins write cards"
 * has allowed them since 0001 and 0025's triggers hold them to the rules --
 * which means the server's refusals are SENTENCES, and this screen shows them
 * exactly as they arrive rather than translating them into something vaguer.
 */

/** The retired ones are shown too. A card is retired, never deleted -- every
 *  saved kingdom points at it by slug and every live match carries a copy --
 *  so "the roster" here means every card that has ever existed. */
type Row = Card & { is_active: boolean }

const BLANK: Omit<Row, 'id'> = {
  slug: '', name: '', hp: 80, mov: 2,
  // `range` is the one that is edited; the other four follow it server-side.
  // A new card starts as a Knight rather than as nothing: since 0031 an
  // active card must have one of the five classes, and '' is not one.
  role: 'knight',
  range: 1, rmin: 1, rmax: 1, crmin: 1, crmax: 1, dmin: 15, dmax: 25, power: 20,
  parry_pct: 5, crit_pct: 5, parry_all: false, royal: false,
  burns: false, heals: false, tramples: false, flies: false,
  sneaks: false, cures: false, parries: false, blooms: false,
  ability: '', ability_es: null, accent: '#2f4bff', art_url: null,
  sort: 99, is_active: true,
}

const NUMBERS = [
  ['hp', 'HP'], ['power', 'Power'], ['mov', 'Move'],
  // ONE BOX, not four. Since 0030 `range` is the only reach number anybody
  // sets: a range of N means every tile from 1 to N, for striking and for
  // answering alike, and the trigger derives rmin/rmax/crmin/crmax from it on
  // the way in. Four boxes with an unwritten invariant between them is four
  // ways to make a card that cannot be hit from next door.
  ['range', 'Range (1 to N tiles)'],
  ['parry_pct', 'Parry %'], ['crit_pct', 'Crit %'], ['sort', 'Sort'],
] as const

const FLAGS = [
  ['royal', 'Royal'], ['parry_all', 'Parries parries'], ['parries', 'Parries'],
  ['burns', 'Burns'], ['heals', 'Heals'], ['cures', 'Cures'],
  ['flies', 'Flies'], ['sneaks', 'Sneaks'], ['tramples', 'Tramples'],
  ['blooms', 'Blooms'],
] as const

export function AdminCards() {
  const [rows, setRows] = useState<Row[]>([])
  const [openId, setOpenId] = useState<string | null>(null)
  const [draft, setDraft] = useState<Row | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('cards').select('*').order('sort')
    if (error) { setErr(error.message); return }
    setRows((data ?? []) as Row[])
  }, [])
  useEffect(() => { void load() }, [load])

  function open(r: Row) {
    setErr(null); setNote(null)
    setOpenId(r.id); setDraft({ ...r })
  }
  function blank() {
    setErr(null); setNote(null)
    setOpenId('new'); setDraft({ id: 'new', ...BLANK })
  }
  const set = (patch: Partial<Row>) => setDraft((d) => (d ? { ...d, ...patch } : d))

  async function save() {
    if (!draft) return
    setBusy(true); setErr(null); setNote(null)
    // id is the database's, and `new` is this screen's word for "there is not
    // one yet" -- neither belongs in the row being written.
    const { id, ...body } = draft
    const q = id === 'new'
      ? supabase.from('cards').insert(body).select('*').single()
      : supabase.from('cards').update(body).eq('id', id).select('*').single()
    const { data, error } = await q
    setBusy(false)
    if (error) {
      // Verbatim. 0025's refusals are sentences written to be read by whoever
      // is editing the card -- "an accent is six hex digits, like #2f4bff" is
      // more use than anything this screen could say instead.
      setErr(error.message.replace(/^.*?:\s*/, ''))
      return
    }
    const row = data as Row
    setNote(`Saved ${row.name}.`)
    setOpenId(row.id); setDraft({ ...row })
    // Every other screen reads the roster from one cached fetch, and a card
    // that has just been retuned is exactly the one they should not be showing
    // the old numbers for.
    clearCards()
    void load()
  }

  return (
    <div className="admin">
      <div className="admin-list">
        <button className="btn small" onClick={blank}>New card</button>
        {rows.map((r) => (
          <button
            key={r.id} type="button"
            className={`admin-row${r.id === openId ? ' is-open' : ''}` +
                       `${r.is_active ? '' : ' is-retired'}`}
            onClick={() => open(r)}
          >
            <span className="admin-swatch" style={{ background: r.accent }} aria-hidden="true" />
            <span className="admin-rowname">{r.name || r.slug || '(no name)'}</span>
            {r.royal && <span className="admin-tag">crown</span>}
            {!r.is_active && <span className="admin-tag">retired</span>}
          </button>
        ))}
      </div>

      {draft && (
        <form className="admin-form" onSubmit={(e) => { e.preventDefault(); void save() }}>
          <div className="admin-grid">
            <label><span>Slug</span>
              <input value={draft.slug ?? ''} onChange={(e) => set({ slug: e.target.value })} />
            </label>
            <label><span>Name</span>
              <input value={draft.name ?? ''} onChange={(e) => set({ name: e.target.value })} />
            </label>
            <label><span>Role</span>
              {/* A picker, not a text box. Since 0031 a class is one of five
                  checked values -- it is what the Royal auras match on -- so
                  typing "Swordsmen" here would be a card the server refuses,
                  and finding that out on Save is a worse way to learn it. */}
              <select value={draft.role ?? ''} onChange={(e) => set({ role: e.target.value })}>
                <option value="royal">Royal</option>
                <option value="rogue">Rogue</option>
                <option value="knight">Knight</option>
                <option value="mage">Mage</option>
                <option value="flying">Flying</option>
              </select>
            </label>
            <label className="admin-colour"><span>Accent</span>
              <input
                type="color" value={/^#[0-9a-fA-F]{6}$/.test(draft.accent) ? draft.accent : '#2f4bff'}
                onChange={(e) => set({ accent: e.target.value })}
              />
              <input
                className="admin-hex" value={draft.accent ?? ''}
                onChange={(e) => set({ accent: e.target.value })}
              />
            </label>
          </div>

          <div className="admin-grid admin-nums">
            {NUMBERS.map(([k, label]) => (
              <label key={k}><span>{label}</span>
                <input
                  type="number" value={(draft[k] ?? 0) as number}
                  onChange={(e) => set({ [k]: Number(e.target.value) } as Partial<Row>)}
                />
              </label>
            ))}
          </div>

          <div className="admin-flags">
            {FLAGS.map(([k, label]) => (
              <label key={k} className="admin-flag">
                <input
                  type="checkbox" checked={Boolean(draft[k])}
                  onChange={(e) => set({ [k]: e.target.checked } as Partial<Row>)}
                />
                <span>{label}</span>
              </label>
            ))}
          </div>

          {/* The brackets are the tooltips -- see keywords.ts. Written here
              rather than left to be remembered, because this is the only place
              anybody types an ability. */}
          <label className="admin-wide"><span>
            Ability (English) — a number in brackets becomes the tooltip on the
            word in front of it: <code>Slightly (5%→10%) increased</code>
          </span>
            <textarea rows={2} value={draft.ability ?? ''}
                      onChange={(e) => set({ ability: e.target.value })} />
          </label>
          <label className="admin-wide"><span>Ability (Spanish)</span>
            <textarea rows={2} value={draft.ability_es ?? ''}
                      onChange={(e) => set({ ability_es: e.target.value || null })} />
          </label>

          <Art draft={draft} set={set} onError={setErr} />

          <AudioFields draft={draft} set={set} onError={setErr} />

          <label className="admin-flag admin-wide">
            <input
              type="checkbox" checked={draft.is_active}
              onChange={(e) => set({ is_active: e.target.checked })}
            />
            <span>
              In the game. Unticking RETIRES the card: it stops being pickable
              and every kingdom holding it stops being fieldable. Nothing is
              deleted, and matches already running keep their copy.
            </span>
          </label>

          <div className="actionbar admin-acts">
            <button className="btn primary" disabled={busy}>
              {busy ? 'Saving…' : 'Save'}
            </button>
            <button
              type="button" className="btn ghost" disabled={busy}
              onClick={() => { const r = rows.find((x) => x.id === openId); if (r) open(r) }}
            >
              Revert
            </button>
            {note && <span className="savemark">{note}</span>}
          </div>
          {err && <p className="error admin-wide">{err}</p>}
        </form>
      )}
    </div>
  )
}

/**
 * The two pictures.
 *
 * The board draws a zoomed crop and the card draws the whole illustration, and
 * the crop lives beside the full picture under the same name with `-face` on
 * the end -- by convention rather than by column, which is a decision from
 * 0005 that this screen has to keep rather than re-open. So BOTH paths are
 * derived from the full art's, and uploading the crop on its own still puts it
 * where faceUrl() will look.
 */
function Art({ draft, set, onError }: {
  draft: Card & { is_active: boolean }
  set: (patch: Partial<Card>) => void
  onError: (m: string | null) => void
}) {
  const [busy, setBusy] = useState<'full' | 'face' | null>(null)
  const full = useRef<HTMLInputElement>(null)
  const face = useRef<HTMLInputElement>(null)

  const ext = (() => {
    const m = (draft.art_url ?? '').match(/\.([a-z0-9]+)(?:\?|$)/i)
    return m ? m[1] : 'webp'
  })()

  async function put(which: 'full' | 'face', file: File) {
    if (!draft.slug) { onError('Give the card a slug first — the art is stored under it.'); return }
    setBusy(which); onError(null)
    const useExt = which === 'full' ? (file.name.split('.').pop() || 'webp') : ext
    const path = `cards/${draft.slug}${which === 'face' ? '-face' : ''}.${useExt}`
    const { error } = await supabase.storage.from('art')
      .upload(path, file, { upsert: true, contentType: file.type || undefined })
    setBusy(null)
    if (error) { onError(error.message); return }
    if (which === 'full') {
      const { data } = supabase.storage.from('art').getPublicUrl(path)
      // A cache-buster, because the URL does not change when the bytes do and
      // an art fix that nobody can see is an art fix nobody made.
      set({ art_url: `${data.publicUrl}?v=${Date.now().toString(36)}` })
    }
  }

  return (
    <div className="admin-art admin-wide">
      <div className="admin-arts">
        <figure>
          <img src={artUrl(draft.art_url) ?? ''} alt="" />
          <figcaption>Full art</figcaption>
          <input
            ref={full} type="file" accept="image/*"
            onChange={(e) => { const f = e.target.files?.[0]; if (f) void put('full', f) }}
          />
        </figure>
        <figure>
          <img src={faceUrl(draft.art_url) ?? ''} alt="" />
          <figcaption>Token crop</figcaption>
          <input
            ref={face} type="file" accept="image/*"
            onChange={(e) => { const f = e.target.files?.[0]; if (f) void put('face', f) }}
          />
        </figure>
      </div>
      <label className="admin-wide"><span>Art URL</span>
        <input value={draft.art_url ?? ''} onChange={(e) => set({ art_url: e.target.value || null })} />
      </label>
      {busy && <p className="muted tiny">Uploading the {busy === 'full' ? 'art' : 'crop'}…</p>}
    </div>
  )
}

/**
 * Four sounds, since 0040: attack, ability, passive and walking. Every one
 * is optional -- an empty set of four is a card that sounds exactly like it
 * always has, because sfx.ts's synthesised set never goes away. What is
 * uploaded here plays ALONGSIDE that, from wherever the game already cues a
 * beat for this kind (see Duel.tsx and Board.tsx) -- there is no separate
 * "does this card have custom audio" switch, a file here simply is the
 * switch.
 *
 * Same storage convention as Art: the path is built from the card's slug, so
 * give it one before trying to upload anything.
 */
const AUDIO_KINDS = [
  ['audio_attack_url', 'Attack', 'Plays alongside the strike sound, when this card lands a blow or a counter.'],
  ['audio_ability_url', 'Ability', 'Plays alongside a heal or an ability-driven hit -- see abilityKind.'],
  ['audio_passive_url', 'Passive', 'Plays alongside a parry or a burn tick this card causes.'],
  ['audio_walk_url', 'Walking', 'Plays when this card moves on its own turn (not while being deployed).'],
] as const satisfies readonly (readonly [keyof Card, string, string])[]

function AudioFields({ draft, set, onError }: {
  draft: Card & { is_active: boolean }
  set: (patch: Partial<Card>) => void
  onError: (m: string | null) => void
}) {
  const [busy, setBusy] = useState<string | null>(null)

  async function put(column: (typeof AUDIO_KINDS)[number][0], file: File) {
    if (!draft.slug) { onError('Give the card a slug first — sounds are stored under it.'); return }
    setBusy(column); onError(null)
    const kind = column.replace(/^audio_/, '').replace(/_url$/, '')
    const ext = file.name.split('.').pop() || 'mp3'
    const path = `cards/${draft.slug}-${kind}.${ext}`
    const { error } = await supabase.storage.from('audio')
      .upload(path, file, { upsert: true, contentType: file.type || undefined })
    setBusy(null)
    if (error) { onError(error.message); return }
    const { data } = supabase.storage.from('audio').getPublicUrl(path)
    // A cache-buster, for the same reason Art's does: the URL does not
    // change when the bytes do, and a fixed sound is a fixed sound nobody's
    // browser has actually re-downloaded.
    set({ [column]: `${data.publicUrl}?v=${Date.now().toString(36)}` } as Partial<Card>)
  }

  return (
    <div className="admin-audio admin-wide">
      <span className="admin-audiolabel">
        Sounds — .wav or .mp3. Each one plays on top of the built-in sound for
        the same moment, never in place of it.
      </span>
      <div className="admin-audiogrid">
        {AUDIO_KINDS.map(([col, label, note]) => {
          const url = draft[col] as string | null | undefined
          return (
            <div key={col} className="admin-audiofield">
              <span className="admin-audiofield-label">{label}</span>
              <span className="admin-audiofield-note">{note}</span>
              <input
                type="file" accept="audio/*"
                onChange={(e) => { const f = e.target.files?.[0]; if (f) void put(col, f) }}
              />
              {url && (
                <div className="admin-audioplayer">
                  {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
                  <audio controls src={url} />
                  <button
                    type="button" className="btn small ghost"
                    onClick={() => set({ [col]: null } as Partial<Card>)}
                  >
                    Clear
                  </button>
                </div>
              )}
              {busy === col && <span className="muted tiny">Uploading…</span>}
            </div>
          )
        })}
      </div>
    </div>
  )
}
