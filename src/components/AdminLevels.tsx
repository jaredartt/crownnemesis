import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { levelInfo, refreshProgression } from '../lib/progression'
import {
  FRAME_STYLES, SHEENS, hex, readFrameData, readNameData, readUnitData,
} from '../lib/skinStyle'
import type { Skin, SkinKind, XpLevel, XpRule, XpSettings } from '../lib/types'
import { SkinPreview } from './SkinPreview'
import { LevelBar } from './LevelBar'
import { nameColorStyle } from '../lib/nameColors'

/**
 * 0188. Jared: "earn XP by playing matches (I get to choose them in the admin
 * panel) and earn new skins ... work on a template." Three panes:
 *   XP rules     -- what each kind of match pays for a win / loss / draw
 *                   (+ second place in Royale), the master switch, and the
 *                   minimum match length that pays at all.
 *   Level track  -- XP needed per level, with the skins each level unlocks.
 *   Skins        -- the catalog, edited through a TEMPLATE per kind (unit look,
 *                   avatar frame, name colour) with a live preview.
 * Every write is a plain table write; the real lock is RLS (cn_is_super_admin()).
 */
type Pane = 'rules' | 'levels' | 'skins' | 'players'

export function AdminLevels() {
  const [pane, setPane] = useState<Pane>('rules')
  return (
    <div className="adminlevels">
      <div className="admintabs" role="tablist">
        {([['rules', 'XP rules'], ['levels', 'Level track'], ['skins', 'Skins'], ['players', 'Players']] as const).map(([id, label]) => (
          <button key={id} type="button" role="tab" aria-selected={pane === id}
                  className={pane === id ? 'is-on' : ''} onClick={() => setPane(id)}>{label}</button>
        ))}
      </div>
      {pane === 'rules' && <RulesPane />}
      {pane === 'levels' && <LevelsPane />}
      {pane === 'skins' && <SkinsPane />}
      {pane === 'players' && <PlayersPane />}
    </div>
  )
}

/* ------------------------------------------------------------------ rules */
const RESULTS: XpRule['result'][] = ['win', 'second', 'draw', 'loss']
const RESULT_LABEL: Record<XpRule['result'], string> = { win: 'Win', second: '2nd place', draw: 'Draw', loss: 'Loss' }

function RulesPane() {
  const [rules, setRules] = useState<XpRule[]>([])
  const [settings, setSettings] = useState<XpSettings | null>(null)
  const [dirty, setDirty] = useState<Record<string, number>>({})
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  async function load() {
    const [r, s] = await Promise.all([
      supabase.from('xp_rules').select('*').order('sort'),
      supabase.from('xp_settings').select('*').eq('id', 1).maybeSingle(),
    ])
    setRules((r.data ?? []) as XpRule[]); setSettings((s.data ?? null) as XpSettings | null); setDirty({})
  }
  useEffect(() => { void load() }, [])

  const modes = useMemo(() => {
    const m = new Map<string, XpRule[]>()
    for (const r of rules) m.set(r.mode, [...(m.get(r.mode) ?? []), r])
    return [...m.entries()]
  }, [rules])
  const key = (r: XpRule) => `${r.mode}|${r.result}`

  async function save() {
    setBusy(true); setErr(null); setNote(null)
    try {
      for (const r of rules) {
        const k = key(r)
        if (!(k in dirty)) continue
        const { error } = await supabase.from('xp_rules').update({ xp: dirty[k] }).eq('mode', r.mode).eq('result', r.result)
        if (error) throw error
      }
      if (settings) {
        const { error } = await supabase.from('xp_settings').update({ enabled: settings.enabled, min_turns: settings.min_turns }).eq('id', 1)
        if (error) throw error
      }
      await load(); await refreshProgression()
      setNote('Saved.')
    } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  return (
    <div className="adminlv-pane">
      <p className="muted tiny">
        XP is paid the moment a match finishes, once per player per match. A Royale
        counts as "vs bots only" when no other human sat down. Leave a cell at 0
        to pay nothing for it.
      </p>
      {settings && (
        <div className="admin-grid">
          <label className="admin-flag admin-wide">
            <input type="checkbox" checked={settings.enabled}
                   onChange={(e) => setSettings({ ...settings, enabled: e.target.checked })} />
            <span>XP is switched on (off = nobody earns anything, nothing else changes).</span>
          </label>
          <label><span>Minimum match length (turns) — shorter matches pay nothing</span>
            <input type="number" min={0} value={settings.min_turns}
                   onChange={(e) => setSettings({ ...settings, min_turns: Math.max(0, Number(e.target.value)) })} />
          </label>
        </div>
      )}
      <table className="adminlv-table">
        <thead><tr><th>Mode</th>{RESULTS.map((r) => <th key={r}>{RESULT_LABEL[r]}</th>)}</tr></thead>
        <tbody>
          {modes.map(([mode, rs]) => (
            <tr key={mode}>
              <td>{rs[0].label || mode}</td>
              {RESULTS.map((res) => {
                const r = rs.find((x) => x.result === res)
                if (!r) return <td key={res} className="muted">—</td>
                const k = key(r)
                return (
                  <td key={res}>
                    <input type="number" min={0} value={k in dirty ? dirty[k] : r.xp}
                           onChange={(e) => setDirty({ ...dirty, [k]: Math.max(0, Math.round(Number(e.target.value))) })} />
                  </td>
                )
              })}
            </tr>
          ))}
        </tbody>
      </table>
      <div className="actionbar admin-acts">
        <button className="btn primary" disabled={busy} onClick={() => void save()}>{busy ? 'Saving…' : 'Save'}</button>
        {note && <span className="savemark">{note}</span>}
      </div>
      {err && <p className="error">{err}</p>}
    </div>
  )
}

/* ----------------------------------------------------------------- levels */
function LevelsPane() {
  const [levels, setLevels] = useState<XpLevel[]>([])
  const [skins, setSkins] = useState<Skin[]>([])
  const [count, setCount] = useState(30)
  const [first, setFirst] = useState(100)
  const [step, setStep] = useState(50)
  const [edit, setEdit] = useState<Record<number, number>>({})
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  async function load() {
    const [l, s] = await Promise.all([
      supabase.from('xp_levels').select('*').order('level'),
      supabase.from('skins').select('*').order('sort'),
    ])
    setLevels((l.data ?? []) as XpLevel[]); setSkins((s.data ?? []) as Skin[]); setEdit({})
  }
  useEffect(() => { void load() }, [])

  const total = (l: XpLevel) => (l.level in edit ? edit[l.level] : l.xp_total)
  const problems = levels.some((l, i) => i > 0 && total(l) <= total(levels[i - 1]))

  async function saveEdits() {
    setBusy(true); setErr(null); setNote(null)
    try {
      for (const l of levels) {
        if (!(l.level in edit)) continue
        const { error } = await supabase.from('xp_levels').update({ xp_total: edit[l.level] }).eq('level', l.level)
        if (error) throw error
      }
      await load(); await refreshProgression(); setNote('Saved.')
    } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  /** total(L) = first*(L-1) + step*(L-1)(L-2)/2 -- level 2 costs `first`, and
   *  every level after costs `step` more than the one before. */
  async function generate() {
    setBusy(true); setErr(null); setNote(null)
    try {
      const n = Math.max(2, Math.min(200, Math.round(count)))
      const rows = Array.from({ length: n }, (_, i) => {
        const L = i + 1
        return { level: L, xp_total: L === 1 ? 0 : Math.round(first * (L - 1) + (step * (L - 1) * (L - 2)) / 2) }
      })
      const { error: dErr } = await supabase.from('xp_levels').delete().gt('level', n)
      if (dErr) throw dErr
      const { error } = await supabase.from('xp_levels').upsert(rows)
      if (error) throw error
      await load(); await refreshProgression(); setNote(`Generated ${n} levels.`)
    } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  const byLevel = useMemo(() => {
    const m = new Map<number, Skin[]>()
    for (const s of skins) if (s.unlock_level != null) m.set(s.unlock_level, [...(m.get(s.unlock_level) ?? []), s])
    return m
  }, [skins])

  return (
    <div className="adminlv-pane">
      <div className="admin-grid">
        <label><span>Levels</span><input type="number" min={2} max={200} value={count} onChange={(e) => setCount(Number(e.target.value))} /></label>
        <label><span>XP to reach level 2</span><input type="number" min={1} value={first} onChange={(e) => setFirst(Number(e.target.value))} /></label>
        <label><span>Each level costs this much MORE than the last</span><input type="number" min={0} value={step} onChange={(e) => setStep(Number(e.target.value))} /></label>
      </div>
      <div className="actionbar admin-acts">
        <button className="btn small" disabled={busy} onClick={() => void generate()}>Generate track (replaces the numbers below)</button>
      </div>
      <table className="adminlv-table">
        <thead><tr><th>Level</th><th>Total XP to reach it</th><th>XP for this level</th><th>Unlocks</th></tr></thead>
        <tbody>
          {levels.map((l, i) => (
            <tr key={l.level}>
              <td>{l.level}</td>
              <td>
                {l.level === 1 ? 0 : (
                  <input type="number" min={0} value={total(l)}
                         onChange={(e) => setEdit({ ...edit, [l.level]: Math.max(0, Math.round(Number(e.target.value))) })} />
                )}
              </td>
              <td className="muted">{i < levels.length - 1 ? total(levels[i + 1]) - total(l) : '—'}</td>
              <td>{(byLevel.get(l.level) ?? []).map((s) => <span key={s.id} className="admin-tag">{s.kind === 'unit' ? '⚔ ' : s.kind === 'frame' ? '◯ ' : 'A '}{s.name}</span>)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {problems && <p className="error">Each level must need more total XP than the one before it.</p>}
      <div className="actionbar admin-acts">
        <button className="btn primary" disabled={busy || problems || Object.keys(edit).length === 0} onClick={() => void saveEdits()}>Save edited numbers</button>
        {note && <span className="savemark">{note}</span>}
      </div>
      {err && <p className="error">{err}</p>}
    </div>
  )
}

/* ------------------------------------------------------------------ skins */
const FRAME_STYLE_LABEL: Record<string, string> = {
  solid: 'Solid (colour 1)', linear: 'Linear gradient', conic: 'Rainbow sweep (loops)',
  radial: 'Edge fade (inner → outer)', duo: 'Two-tone split',
}
const KIND_LABEL: Record<SkinKind, string> = { unit: 'Unit look', frame: 'Avatar frame', name_color: 'Name colour' }
const KIND_GROUP: Record<SkinKind, string> = { name_color: 'Name colours', unit: 'Unit looks', frame: 'Avatar frames' }
const NEW_DATA: Record<SkinKind, Record<string, unknown>> = {
  unit: { rim: '#8a94a6', rim_width: 3, glow: null, glow_size: 0, sheen: 'none', sheen_color: '#ffffff', tint: null, tint_alpha: 0 },
  frame: { style: 'linear', ring: '#ffd23f', ring2: '#ff4f9a', ring3: null, angle: 135 },
  name_color: { color: '#2f4bff', color2: null, shimmer: false },
}

function SkinsPane() {
  const [rows, setRows] = useState<Skin[]>([])
  const [draft, setDraft] = useState<Skin | null>(null)
  const [isNew, setIsNew] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [grantTo, setGrantTo] = useState('')

  async function load() {
    const { data } = await supabase.from('skins').select('*').order('kind').order('unlock_level', { nullsFirst: false }).order('sort')
    setRows((data ?? []) as Skin[])
  }
  useEffect(() => { void load() }, [])

  const open = (s: Skin) => { setDraft({ ...s, data: { ...s.data } }); setIsNew(false); setErr(null); setNote(null); setConfirmDelete(false) }
  const blank = (kind: SkinKind) => {
    setDraft({ id: 'new', slug: '', kind, name: '', name_es: null, description: null, description_es: null, unlock_level: 1, data: { ...NEW_DATA[kind] }, is_active: true, sort: 99 })
    setIsNew(true); setErr(null); setNote(null); setConfirmDelete(false)
  }
  const set = (patch: Partial<Skin>) => setDraft((d) => (d ? { ...d, ...patch } : d))
  const setData = (patch: Record<string, unknown>) => setDraft((d) => (d ? { ...d, data: { ...d.data, ...patch } } : d))

  async function save() {
    if (!draft) return
    setBusy(true); setErr(null); setNote(null)
    const { id, ...body } = draft
    const q = isNew
      ? supabase.from('skins').insert(body).select('*').single()
      : supabase.from('skins').update(body).eq('id', id).select('*').single()
    const { data, error } = await q
    setBusy(false)
    if (error) { setErr(error.message.replace(/^.*?:\s*/, '')); return }
    setDraft(data as Skin); setIsNew(false); setNote(`Saved ${(data as Skin).name}.`)
    void load(); void refreshProgression()
  }

  async function del() {
    if (!draft || isNew) return
    setBusy(true); setErr(null)
    const { error } = await supabase.from('skins').delete().eq('id', draft.id)
    setBusy(false)
    if (error) { setErr(error.message); return }
    setDraft(null); setConfirmDelete(false); void load(); void refreshProgression()
  }

  async function grant() {
    if (!draft || isNew || !grantTo.trim()) return
    setBusy(true); setErr(null); setNote(null)
    try {
      const { data: p, error: pe } = await supabase.from('profiles').select('id, username').ilike('username', grantTo.trim()).maybeSingle()
      if (pe || !p) throw new Error('No player with that exact username.')
      const { error } = await supabase.from('user_skins').upsert({ user_id: (p as { id: string }).id, skin_id: draft.id, source: 'admin' })
      if (error) throw error
      setNote(`Gave ${draft.name} to ${(p as { username: string }).username}.`); setGrantTo('')
    } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  const d = draft?.data ?? {}
  const hexField = (label: string, field: string, nullable = false) => (
    <label className="admin-colour"><span>{label}</span>
      <input type="color" value={hex(d[field], '#888888')!}
             onChange={(e) => setData({ [field]: e.target.value })} />
      <input className="admin-hex" value={typeof d[field] === 'string' ? (d[field] as string) : ''} placeholder={nullable ? 'none' : ''}
             onChange={(e) => setData({ [field]: e.target.value === '' && nullable ? null : e.target.value })} />
    </label>
  )
  const numField = (label: string, field: string, min: number, max: number, step = 1) => (
    <label><span>{label}</span>
      <input type="number" min={min} max={max} step={step} value={typeof d[field] === 'number' ? (d[field] as number) : 0}
             onChange={(e) => setData({ [field]: Number(e.target.value) })} />
    </label>
  )

  // What the draft would look like to a player, from the same readers the game uses.
  const preview = draft && ({
    ...draft,
    data: draft.kind === 'unit' ? readUnitData(draft.data) : draft.kind === 'frame' ? readFrameData(draft.data) : readNameData(draft.data),
  } as unknown as Skin)

  return (
    <div className="admin">
      <div className="admin-list">
        <div className="adminlv-new">
          {(['name_color', 'frame', 'unit'] as SkinKind[]).map((k) => (
            <button key={k} className="btn small" onClick={() => blank(k)}>New {KIND_LABEL[k].toLowerCase()}</button>
          ))}
        </div>
        {(['name_color', 'unit', 'frame'] as SkinKind[]).map((k) => {
          const group = rows.filter((r) => r.kind === k)
          return (
            <div key={k} className="adminlv-group">
              <h4 className="adminlv-grouphead">{KIND_GROUP[k]} <span>{group.length}</span></h4>
              {group.map((r) => (
                <button key={r.id} type="button"
                        className={`admin-row${draft?.id === r.id ? ' is-open' : ''}${r.is_active ? '' : ' is-retired'}`}
                        onClick={() => open(r)}>
                  <span className="admin-rowname">{r.name || r.slug}</span>
                  <span className="admin-tag">{r.unlock_level != null ? `Lv ${r.unlock_level}` : 'gift'}</span>
                </button>
              ))}
              {group.length === 0 && <span className="muted tiny">None yet.</span>}
            </div>
          )
        })}
      </div>

      {draft && (
        <form className="admin-form" onSubmit={(e) => { e.preventDefault(); void save() }}>
          <div className="actionbar admin-acts admin-acts-top">
            <button className="btn primary" disabled={busy}>{busy ? 'Saving…' : 'Save'}</button>
            {!isNew && (confirmDelete ? (
              <>
                <span className="admin-bantext">Delete {draft.name} for everyone? Players wearing it fall back to the default.</span>
                <button type="button" className="btn danger small" disabled={busy} onClick={() => void del()}>Yes, delete</button>
                <button type="button" className="btn ghost small" onClick={() => setConfirmDelete(false)}>No</button>
              </>
            ) : (
              <button type="button" className="btn danger small" onClick={() => setConfirmDelete(true)}>Delete permanently</button>
            ))}
            {note && <span className="savemark">{note}</span>}
          </div>
          {err && <p className="error admin-wide">{err}</p>}

          <div className="adminlv-preview admin-wide">
            {preview && <SkinPreview skin={preview} face="mako" name="Preview" />}
            <span className="muted tiny">{KIND_LABEL[draft.kind]} — exactly what a player sees.</span>
          </div>

          <div className="admin-grid">
            <label><span>Slug {isNew ? '(a-z, 0-9, _ — cannot change later)' : '(fixed)'}</span>
              <input value={draft.slug} disabled={!isNew} onChange={(e) => set({ slug: e.target.value })} />
            </label>
            <label><span>Name</span><input value={draft.name} onChange={(e) => set({ name: e.target.value })} /></label>
            <label><span>Name (Spanish)</span><input value={draft.name_es ?? ''} onChange={(e) => set({ name_es: e.target.value || null })} /></label>
            <label><span>Unlocks at level (empty = admin gift only)</span>
              <input type="number" min={1} value={draft.unlock_level ?? ''}
                     onChange={(e) => set({ unlock_level: e.target.value === '' ? null : Math.max(1, Number(e.target.value)) })} />
            </label>
            <label><span>Sort</span><input type="number" value={draft.sort} onChange={(e) => set({ sort: Number(e.target.value) })} /></label>

            {draft.kind === 'unit' && (
              <>
                {hexField('Rim colour', 'rim')}
                {numField('Rim width (px)', 'rim_width', 1, 6)}
                {hexField('Glow colour', 'glow', true)}
                {numField('Glow size (px)', 'glow_size', 0, 24)}
                <label><span>Sheen</span>
                  <select value={String(d.sheen ?? 'none')} onChange={(e) => setData({ sheen: e.target.value })}>
                    {SHEENS.map((s) => <option key={s} value={s}>{s}</option>)}
                  </select>
                </label>
                {hexField('Sheen colour', 'sheen_color')}
                {hexField('Tint over the art', 'tint', true)}
                {numField('Tint strength (0-0.5)', 'tint_alpha', 0, 0.5, 0.05)}
              </>
            )}
            {draft.kind === 'frame' && (
              <>
                <label><span>Gradient style</span>
                  <select value={String(d.style ?? 'solid')} onChange={(e) => setData({ style: e.target.value })}>
                    {FRAME_STYLES.map((s) => <option key={s} value={s}>{FRAME_STYLE_LABEL[s]}</option>)}
                  </select>
                </label>
                {numField('Angle (°, for linear / conic / two-tone)', 'angle', 0, 360, 15)}
                {hexField('Colour 1', 'ring')}
                {hexField('Colour 2', 'ring2', true)}
                {hexField('Colour 3 (optional)', 'ring3', true)}
                <p className="muted tiny admin-wide">Frames are flat rings: no glow, no animation, and the thickness is always the same share of the picture.</p>
              </>
            )}
            {draft.kind === 'name_color' && (
              <>
                {typeof d.var === 'string' && <p className="muted tiny admin-wide">Built-in theme colour ({String(d.var)}) — it adapts to light/dark. To make it custom, clear the “var” by making a new one instead.</p>}
                {hexField('Colour', 'color')}
                {hexField('Second colour (makes a gradient)', 'color2', true)}
                <label className="admin-flag admin-wide">
                  <input type="checkbox" checked={d.shimmer === true} onChange={(e) => setData({ shimmer: e.target.checked })} />
                  <span>Shimmer (the gradient slowly slides)</span>
                </label>
              </>
            )}
            <label className="admin-wide"><span>Description (shown on hover)</span>
              <textarea rows={2} value={draft.description ?? ''} onChange={(e) => set({ description: e.target.value || null })} />
            </label>
          </div>
          <label className="admin-flag admin-wide">
            <input type="checkbox" checked={draft.is_active} onChange={(e) => set({ is_active: e.target.checked })} />
            <span>Offered to players. Untick to retire it (nobody can equip it any more).</span>
          </label>

          {!isNew && (
            <div className="admin-grid admin-wide">
              <label><span>Give this skin to a player (exact username)</span>
                <input value={grantTo} onChange={(e) => setGrantTo(e.target.value)} />
              </label>
              <button type="button" className="btn small" disabled={busy || !grantTo.trim()} onClick={() => void grant()}>Give it</button>
            </div>
          )}
        </form>
      )}
    </div>
  )
}

/* ---------------------------------------------------------------- players */
interface PRow { id: string; username: string; xp: number }
interface EvRow { id: number; ref: string; mode: string; result: string; xp: number; level_before: number; level_after: number; created_at: string }
interface GrantRow { skin_id: string; source: string; skins: { name: string; kind: SkinKind } | null }

/** Look up anyone, see their level/XP and history, and add / remove / set XP or
 *  jump them to a level (admin_adjust_xp -- logged), and give or take skins. */
function PlayersPane() {
  const [q, setQ] = useState('')
  const [list, setList] = useState<PRow[]>([])
  const [sel, setSel] = useState<PRow | null>(null)
  const [levels, setLevels] = useState<XpLevel[]>([])
  const [skins, setSkins] = useState<Skin[]>([])
  const [events, setEvents] = useState<EvRow[]>([])
  const [grants, setGrants] = useState<GrantRow[]>([])
  const [amount, setAmount] = useState(100)
  const [exact, setExact] = useState(0)
  const [lvl, setLvl] = useState(2)
  const [giveId, setGiveId] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  async function search(text = q) {
    let query = supabase.from('profiles').select('id, username, xp').eq('is_system', false).order('xp', { ascending: false }).limit(30)
    if (text.trim()) query = query.ilike('username', `%${text.trim().replace(/[%_]/g, '')}%`)
    const { data } = await query
    setList((data ?? []) as PRow[])
  }
  useEffect(() => {
    void search('')
    void Promise.all([supabase.from('xp_levels').select('*').order('level'), supabase.from('skins').select('*').order('kind').order('sort')])
      .then(([l, k]) => { setLevels((l.data ?? []) as XpLevel[]); setSkins((k.data ?? []) as Skin[]) })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function loadPlayer(p: PRow) {
    setSel(p); setErr(null); setNote(null); setExact(p.xp)
    const [fresh, ev, gr] = await Promise.all([
      supabase.from('profiles').select('id, username, xp').eq('id', p.id).single(),
      supabase.from('xp_events').select('*').eq('user_id', p.id).order('created_at', { ascending: false }).limit(25),
      supabase.from('user_skins').select('skin_id, source, skins(name, kind)').eq('user_id', p.id),
    ])
    if (fresh.data) { setSel(fresh.data as PRow); setExact((fresh.data as PRow).xp) }
    setEvents((ev.data ?? []) as EvRow[]); setGrants((gr.data ?? []) as unknown as GrantRow[])
  }

  async function adjust(op: 'add' | 'set' | 'level', value: number, what: string) {
    if (!sel) return
    setBusy(true); setErr(null); setNote(null)
    const { data, error } = await supabase.rpc('admin_adjust_xp', { p_user: sel.id, p_op: op, p_value: Math.round(value) })
    setBusy(false)
    if (error) { setErr(error.message.replace(/^.*?:\s*/, '')); return }
    const r = (data as { xp: number; level: number }[])[0]
    setNote(`${what}: ${sel.username} is now level ${r.level} with ${r.xp} XP.`)
    await loadPlayer({ ...sel, xp: r.xp }); void search()
  }

  async function give() {
    if (!sel || !giveId) return
    setBusy(true); setErr(null); setNote(null)
    const { error } = await supabase.from('user_skins').upsert({ user_id: sel.id, skin_id: giveId, source: 'admin' })
    setBusy(false)
    if (error) { setErr(error.message); return }
    setGiveId(''); setNote('Skin given.'); await loadPlayer(sel)
  }
  async function revoke(skinId: string) {
    if (!sel) return
    setBusy(true); setErr(null)
    const { error } = await supabase.from('user_skins').delete().eq('user_id', sel.id).eq('skin_id', skinId)
    setBusy(false)
    if (error) { setErr(error.message); return }
    await loadPlayer(sel)
  }

  const info = sel ? levelInfo(levels, sel.xp) : null
  const when = (iso: string) => new Date(iso).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
  const label = (e: EvRow) => e.mode === 'admin'
    ? `Admin · ${e.result === 'add' ? 'added/removed' : e.result === 'set' ? 'set exact XP' : 'jumped to a level'}`
    : `${e.mode.replace('_', ' ')} · ${e.result}`

  return (
    <div className="admin">
      <div className="admin-list">
        <form className="adminlv-search" onSubmit={(e) => { e.preventDefault(); void search() }}>
          <input placeholder="Search a username…" value={q} onChange={(e) => setQ(e.target.value)} />
          <button className="btn small">Search</button>
        </form>
        {list.map((p) => (
          <button key={p.id} type="button" className={`admin-row${sel?.id === p.id ? ' is-open' : ''}`} onClick={() => void loadPlayer(p)}>
            <span className="admin-rowname" style={nameColorStyle(null)}>{p.username}</span>
            <span className="admin-tag">Lv {levelInfo(levels, p.xp).level} · {p.xp} XP</span>
          </button>
        ))}
      </div>

      {sel && info && (
        <div className="admin-form adminlv-player">
          <h3 className="adminlv-h">{sel.username}</h3>
          <LevelBar xp={sel.xp} />
          <p className="muted tiny">
            Level {info.level} · {sel.xp} XP total{info.nextAt != null ? ` · next level at ${info.nextAt} XP` : ' · top level'}
          </p>
          {err && <p className="error">{err}</p>}
          {note && <p className="savemark">{note}</p>}

          <div className="adminlv-ops">
            <label><span>Add or remove XP</span>
              <input type="number" value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
            </label>
            <button className="btn small" disabled={busy} onClick={() => void adjust('add', Math.abs(amount), 'Added')}>Add</button>
            <button className="btn small danger" disabled={busy} onClick={() => void adjust('add', -Math.abs(amount), 'Removed')}>Remove</button>
          </div>
          <div className="adminlv-ops">
            <label><span>Set exact XP</span>
              <input type="number" min={0} value={exact} onChange={(e) => setExact(Number(e.target.value))} />
            </label>
            <button className="btn small" disabled={busy} onClick={() => void adjust('set', exact, 'Set')}>Set</button>
            <button className="btn small ghost" disabled={busy} onClick={() => void adjust('set', 0, 'Reset')}>Reset to 0</button>
          </div>
          <div className="adminlv-ops">
            <label><span>Jump to level (sets XP to that level's threshold)</span>
              <select value={lvl} onChange={(e) => setLvl(Number(e.target.value))}>
                {levels.map((l) => <option key={l.level} value={l.level}>Level {l.level} ({l.xp_total} XP)</option>)}
              </select>
            </label>
            <button className="btn small" disabled={busy} onClick={() => void adjust('level', lvl, 'Jumped')}>Jump</button>
          </div>

          <h4 className="adminlv-h">Skins given outside the level track</h4>
          <div className="adminlv-chips">
            {grants.length === 0 && <span className="muted tiny">None.</span>}
            {grants.map((g) => (
              <span key={g.skin_id} className="admin-tag">
                {g.skins?.name ?? '?'} · {g.source}
                <button type="button" className="adminlv-x" title="Take it away" disabled={busy} onClick={() => void revoke(g.skin_id)}>×</button>
              </span>
            ))}
          </div>
          <div className="adminlv-ops">
            <label><span>Give a skin</span>
              <select value={giveId} onChange={(e) => setGiveId(e.target.value)}>
                <option value="">Choose…</option>
                {(['name_color', 'unit', 'frame'] as SkinKind[]).map((k) => (
                  <optgroup key={k} label={KIND_LABEL[k]}>
                    {skins.filter((x) => x.kind === k).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
                  </optgroup>
                ))}
              </select>
            </label>
            <button className="btn small" disabled={busy || !giveId} onClick={() => void give()}>Give</button>
          </div>

          <h4 className="adminlv-h">XP history (latest 25)</h4>
          <table className="adminlv-table">
            <thead><tr><th>When</th><th>What</th><th>XP</th><th>Level</th></tr></thead>
            <tbody>
              {events.length === 0 && <tr><td colSpan={4} className="muted">No XP yet.</td></tr>}
              {events.map((e) => (
                <tr key={e.id}>
                  <td className="muted">{when(e.created_at)}</td>
                  <td>{label(e)}</td>
                  <td className={e.xp < 0 ? 'adminlv-neg' : 'adminlv-pos'}>{e.xp > 0 ? `+${e.xp}` : e.xp}</td>
                  <td>{e.level_before === e.level_after ? e.level_after : `${e.level_before} → ${e.level_after}`}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
