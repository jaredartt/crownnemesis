import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { adminDeleteAnimation } from '../lib/api'
import type { Animation } from '../lib/types'
import { AnimationFx, type AnimationSpec } from './AnimationFx'

/**
 * 0158. Jared: "Create a new tab inside the admin panel where I can define,
 * create, modify and delete animations... I need a preview of the
 * animation, so create like a small sandbox in it so I can see what they
 * look like." Same list/form/Save-Revert-Delete shell as AdminStructures.tsx
 * (the explicit template he pointed at -- "kind of like how structures
 * work") plus one genuinely new piece below the form: a small mock 3x3
 * board that lights up whichever tile(s) `play_at` would actually target
 * and plays the draft's own AnimationFx on them, live, before anything is
 * saved.
 *
 * No sentence builder here -- an Animation row is not itself attached to
 * anything; it is card_effects' own new `animation_slug` column (via the
 * SentenceBuilder's Animation pill, in AdminCards.tsx) that points AT one
 * of these. This tab only owns the catalog.
 */

const SHAPES: Animation['shape'][] = [
  'round_burst', 'diamond_burst', 'ring_pulse', 'arc_sweep', 'beam_line', 'pulse_only',
]
const SHAPE_LABELS: Record<Animation['shape'], string> = {
  round_burst: 'Round burst (dots)',
  diamond_burst: 'Diamond burst (shards)',
  ring_pulse: 'Ring pulse',
  arc_sweep: 'Arc sweep (e.g. a sword swing)',
  beam_line: 'Beam fan',
  pulse_only: 'Simple pulse',
}
const shapeLabel = (s: Animation['shape']) => SHAPE_LABELS[s] ?? s

// Which of the tunable fields actually do anything for a given shape --
// see AnimationFx.tsx and 0158_animations.sql's own column-by-column
// comment. Hiding a field a shape ignores beats an admin tuning a number
// and wondering why nothing changed.
const SHOWS_PARTICLES = new Set<Animation['shape']>(['round_burst', 'diamond_burst'])
const SHOWS_SPREAD = new Set<Animation['shape']>(['round_burst', 'diamond_burst', 'arc_sweep', 'beam_line'])

const PLAY_ATS: Animation['play_at'][] = ['CASTER', 'TARGET', 'ALL_ALLIES', 'ALL_ENEMIES', 'WHOLE_BOARD']
const PLAY_AT_LABELS: Record<Animation['play_at'], string> = {
  CASTER: "the caster's own tile",
  TARGET: "each tile the sentence's own target resolved to",
  ALL_ALLIES: 'every living ally, regardless of what the sentence itself targets',
  ALL_ENEMIES: 'every living enemy, regardless of what the sentence itself targets',
  WHOLE_BOARD: 'every tile',
}
const playAtLabel = (p: Animation['play_at']) => PLAY_AT_LABELS[p] ?? p

const BLANK: Omit<Animation, 'id'> = {
  slug: '', name: '', name_es: null, description: null, description_es: null,
  shape: 'round_burst', color: '#2f4bff',
  duration_ms: 600, particle_count: 9, spread_deg: 360, radius_px: 42,
  scale_start: 0.6, scale_end: 1.4, opacity_start: 1, opacity_end: 0,
  play_at: 'TARGET', is_active: true, sort: 99,
}

export function AdminAnimations() {
  const [rows, setRows] = useState<Animation[]>([])
  const [openId, setOpenId] = useState<string | null>(null)
  const [draft, setDraft] = useState<Animation | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)

  async function load() {
    const { data, error } = await supabase.from('animations').select('*').order('sort')
    if (error) { setErr(error.message); return }
    setRows((data ?? []) as Animation[])
  }
  useEffect(() => { void load() }, [])

  function open(r: Animation) {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenId(r.id); setDraft({ ...r })
  }
  function blank() {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenId('new'); setDraft({ id: 'new', ...BLANK })
  }
  const set = (patch: Partial<Animation>) => setDraft((d) => (d ? { ...d, ...patch } : d))

  async function save() {
    if (!draft) return
    setBusy(true); setErr(null); setNote(null)
    const { id, ...body } = draft
    const q = id === 'new'
      ? supabase.from('animations').insert(body).select('*').single()
      : supabase.from('animations').update(body).eq('id', id).select('*').single()
    const { data, error } = await q
    setBusy(false)
    if (error) { setErr(error.message.replace(/^.*?:\s*/, '')); return }
    const row = data as Animation
    setOpenId(row.id); setDraft({ ...row })
    setNote(`Saved ${row.name || row.slug}.`)
    void load()
  }

  /** admin_delete_animation() has no "still in use" guard -- unlike
   *  structures/cards, a card_effects row pointing at a deleted animation
   *  just goes back to null (no animation) automatically, see
   *  0158_animations.sql's own comment on the FK. */
  async function deleteForever() {
    if (!draft || draft.id === 'new') return
    setBusy(true); setErr(null); setNote(null)
    try {
      await adminDeleteAnimation(draft.id)
      setNote(`Deleted ${draft.name || draft.slug} permanently.`)
      setConfirmDelete(null); setOpenId(null); setDraft(null)
      void load()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="admin">
      <div className="admin-list">
        <button className="btn small" onClick={blank}>New animation</button>
        {rows.map((r) => (
          <button
            key={r.id} type="button"
            className={`admin-row${r.id === openId ? ' is-open' : ''}` +
                       `${r.is_active ? '' : ' is-retired'}`}
            onClick={() => open(r)}
          >
            <span className="admin-swatch" style={{ background: r.color }} aria-hidden="true" />
            <span className="admin-rowname">{r.name || r.slug || '(no name)'}</span>
            {!r.is_active && <span className="admin-tag">retired</span>}
          </button>
        ))}
      </div>

      {draft && (
        <form className="admin-form" onSubmit={(e) => { e.preventDefault(); void save() }}>
          <div className="actionbar admin-acts admin-acts-top">
            <button className="btn primary" disabled={busy}>
              {busy ? 'Saving…' : 'Save'}
            </button>
            <button
              type="button" className="btn ghost" disabled={busy}
              onClick={() => { const r = rows.find((x) => x.id === openId); if (r) open(r) }}
            >
              Revert
            </button>
            {draft.id !== 'new' && (
              confirmDelete === draft.id ? (
                <>
                  <span className="admin-bantext">
                    Really delete {draft.name || draft.slug} permanently? This cannot be undone.
                  </span>
                  <button
                    type="button" className="btn danger small" disabled={busy}
                    onClick={() => void deleteForever()}
                  >
                    Yes, delete forever
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
                  type="button" className="btn danger small" disabled={busy}
                  onClick={() => setConfirmDelete(draft.id)}
                >
                  Delete permanently
                </button>
              )
            )}
            {note && <span className="savemark">{note}</span>}
          </div>
          {err && <p className="error admin-wide">{err}</p>}

          <div className="admin-grid">
            <label><span>Slug</span>
              <input value={draft.slug} onChange={(e) => set({ slug: e.target.value })} />
            </label>
            <label><span>Name</span>
              <input value={draft.name} onChange={(e) => set({ name: e.target.value })} />
            </label>
            <label><span>Name (Spanish)</span>
              <input
                value={draft.name_es ?? ''}
                onChange={(e) => set({ name_es: e.target.value || null })}
              />
            </label>
            <label><span>Sort</span>
              <input
                type="number" value={draft.sort}
                onChange={(e) => set({ sort: Number(e.target.value) })}
              />
            </label>

            <label><span>Shape</span>
              <select value={draft.shape} onChange={(e) => set({ shape: e.target.value as Animation['shape'] })}>
                {SHAPES.map((s) => <option key={s} value={s}>{shapeLabel(s)}</option>)}
              </select>
            </label>
            <label className="admin-colour"><span>Color</span>
              <input
                type="color" value={draft.color}
                onChange={(e) => set({ color: e.target.value })}
              />
              <input
                className="admin-hex" value={draft.color}
                onChange={(e) => set({ color: e.target.value })}
              />
            </label>
            <label><span>Where it plays</span>
              <select value={draft.play_at} onChange={(e) => set({ play_at: e.target.value as Animation['play_at'] })}>
                {PLAY_ATS.map((p) => <option key={p} value={p}>{playAtLabel(p)}</option>)}
              </select>
            </label>
            <label><span>Duration (ms)</span>
              <input
                type="number" min={50} max={12000} value={draft.duration_ms}
                onChange={(e) => set({ duration_ms: Number(e.target.value) })}
              />
            </label>

            {SHOWS_PARTICLES.has(draft.shape) && (
              <label><span>Particle count</span>
                <input
                  type="number" min={0} max={24} value={draft.particle_count}
                  onChange={(e) => set({ particle_count: Number(e.target.value) })}
                />
              </label>
            )}
            {SHOWS_SPREAD.has(draft.shape) && (
              <label><span>
                Spread (degrees) — {draft.shape === 'arc_sweep'
                  ? 'how far the wedge rotates, 60-90 reads as a swing, 360 as a full spin'
                  : draft.shape === 'beam_line'
                  ? "how wide the beam fan spreads"
                  : '360 = full circle'}
              </span>
                <input
                  type="number" min={1} max={360} value={draft.spread_deg}
                  onChange={(e) => set({ spread_deg: Number(e.target.value) })}
                />
              </label>
            )}
            <label><span>
              Radius (px) — how far a particle travels / an arc's radius /
              a beam's length / a pulse's base size
            </span>
              <input
                type="number" min={1} value={draft.radius_px}
                onChange={(e) => set({ radius_px: Number(e.target.value) })}
              />
            </label>

            <label><span>Scale, start</span>
              <input
                type="number" step={0.1} min={0} value={draft.scale_start}
                onChange={(e) => set({ scale_start: Number(e.target.value) })}
              />
            </label>
            <label><span>Scale, end</span>
              <input
                type="number" step={0.1} min={0} value={draft.scale_end}
                onChange={(e) => set({ scale_end: Number(e.target.value) })}
              />
            </label>
            <label><span>Opacity, start</span>
              <input
                type="number" step={0.05} min={0} max={1} value={draft.opacity_start}
                onChange={(e) => set({ opacity_start: Number(e.target.value) })}
              />
            </label>
            <label><span>Opacity, end</span>
              <input
                type="number" step={0.05} min={0} max={1} value={draft.opacity_end}
                onChange={(e) => set({ opacity_end: Number(e.target.value) })}
              />
            </label>

            <label className="admin-wide"><span>Description (English)</span>
              <textarea rows={2} value={draft.description ?? ''}
                        onChange={(e) => set({ description: e.target.value || null })} />
            </label>
            <label className="admin-wide"><span>Description (Spanish)</span>
              <textarea rows={2} value={draft.description_es ?? ''}
                        onChange={(e) => set({ description_es: e.target.value || null })} />
            </label>
          </div>

          <label className="admin-flag admin-wide">
            <input
              type="checkbox" checked={draft.is_active}
              onChange={(e) => set({ is_active: e.target.checked })}
            />
            <span>
              Offered in the Animation picker on a sentence. Unticking retires
              it there without breaking any sentence already pointed at it --
              it keeps playing wherever it's already attached.
            </span>
          </label>

          <AnimationSandbox spec={draft} />
        </form>
      )}
    </div>
  )
}

// The mock board this sandbox lights up -- nine tiles, laid out so every
// play_at value has somewhere honest to point: a row of allies with the
// caster among them, a row of enemies with the target among them, and one
// spacer tile in the middle that's never a role of its own.
type TileRole = 'ally' | 'caster' | 'enemy' | 'target' | 'spacer'
const TILES: { role: TileRole; label: string }[] = [
  { role: 'ally', label: 'Ally' }, { role: 'ally', label: 'Ally' }, { role: 'ally', label: 'Ally' },
  { role: 'caster', label: 'Caster' }, { role: 'spacer', label: '' }, { role: 'target', label: 'Target' },
  { role: 'enemy', label: 'Enemy' }, { role: 'enemy', label: 'Enemy' }, { role: 'enemy', label: 'Enemy' },
]

function tilesFor(playAt: Animation['play_at']): Set<TileRole> {
  switch (playAt) {
    case 'CASTER': return new Set<TileRole>(['caster'])
    case 'TARGET': return new Set<TileRole>(['target'])
    case 'ALL_ALLIES': return new Set<TileRole>(['ally', 'caster'])
    case 'ALL_ENEMIES': return new Set<TileRole>(['enemy', 'target'])
    case 'WHOLE_BOARD': return new Set<TileRole>(['ally', 'caster', 'enemy', 'target', 'spacer'])
  }
}

function AnimationSandbox({ spec }: { spec: AnimationSpec & { play_at: Animation['play_at'] } }) {
  const [playing, setPlaying] = useState(false)
  const [playKey, setPlayKey] = useState(0)
  const timer = useRef<number | undefined>(undefined)

  useEffect(() => () => { if (timer.current) window.clearTimeout(timer.current) }, [])

  function play() {
    if (timer.current) window.clearTimeout(timer.current)
    setPlayKey((k) => k + 1)
    setPlaying(true)
    timer.current = window.setTimeout(() => setPlaying(false), spec.duration_ms + 150)
  }

  const active = tilesFor(spec.play_at)

  return (
    <div className="admin-wide animfx-sandbox">
      <div className="animfx-sandbox-head">
        <h3>Preview</h3>
        <button type="button" className="btn small" onClick={play}>
          {playing ? 'Playing…' : 'Play'}
        </button>
      </div>
      <p className="muted tiny">
        A mock board, not a real match — shows exactly which tile(s) "{playAtLabel(spec.play_at)}"
        would light up and how this shape/color/timing combination looks on
        one of them. Reflects the form above, unsaved changes included.
      </p>
      <div className="animfx-scene">
        {TILES.map((t, i) => {
          const isActive = t.role !== 'spacer' && active.has(t.role)
          return (
            <div key={i} className={`animfx-tile${isActive && playing ? ' is-playing' : ''}`}>
              {t.label}
              {isActive && playing && <AnimationFx key={playKey} spec={spec} />}
            </div>
          )
        })}
      </div>
    </div>
  )
}
