import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { refreshProgression } from '../lib/progression'
import {
  FRAME_ANIMS, SHEENS, hex, readFrameData, readNameData, readUnitData,
} from '../lib/skinStyle'
import type { Skin, SkinKind, XpLevel, XpRule, XpSettings } from '../lib/types'
import { SkinPreview } from './SkinPreview'

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
type Pane = 'rules' | 'levels' | 'skins'

export function AdminLevels() {
  const [pane, setPane] = useState<Pane>('rules')
  return (
    <div className="adminlevels">
      <div className="admintabs" role="tablist">
        {([['rules', 'XP rules'], ['levels', 'Level track'], ['skins', 'Skins']] as const).map(([id, label]) => (
          <button key={id} type="button" role="tab" aria-selected={pane === id}
                  className={pane === id ? 'is-on' : ''} onClick={() => setPane(id)}>{label}</button>
        ))}
      </div>
      {pane === 'rules' && <RulesPane />}
      {pane === 'levels' && <LevelsPane />}
      {pane === 'skins' && <SkinsPane />}
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
const KIND_LABEL: Record<SkinKind, string> = { unit: 'Unit look', frame: 'Avatar frame', name_color: 'Name colour' }
const NEW_DATA: Record<SkinKind, Record<string, unknown>> = {
  unit: { rim: '#8a94a6', rim_width: 3, glow: null, glow_size: 0, sheen: 'none', sheen_color: '#ffffff', tint: null, tint_alpha: 0 },
  frame: { ring: '#c9d1dc', ring2: null, width: 4, glow: null, anim: 'none' },
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
        {rows.map((r) => (
          <button key={r.id} type="button"
                  className={`admin-row${draft?.id === r.id ? ' is-open' : ''}${r.is_active ? '' : ' is-retired'}`}
                  onClick={() => open(r)}>
            <span className="admin-rowname">{r.name || r.slug}</span>
            <span className="admin-tag">{KIND_LABEL[r.kind]} · {r.unlock_level != null ? `Lv ${r.unlock_level}` : 'gift'}</span>
          </button>
        ))}
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
                {hexField('Ring colour', 'ring')}
                {hexField('Second ring colour (gradient)', 'ring2', true)}
                {numField('Ring width (px)', 'width', 2, 8)}
                {hexField('Glow colour', 'glow', true)}
                <label><span>Animation</span>
                  <select value={String(d.anim ?? 'none')} onChange={(e) => setData({ anim: e.target.value })}>
                    {FRAME_ANIMS.map((s) => <option key={s} value={s}>{s}</option>)}
                  </select>
                </label>
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
