import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { adminDeleteStructure } from '../lib/api'
import type { Structure, StructureEffect } from '../lib/types'
import {
  SentenceBuilder, groupSentences, type SentenceVocab, type SentenceRow,
} from './SentenceBuilder'

/**
 * The structures editor, since 0057. Same shape as AdminCards.tsx's card
 * screen -- a list on the left, an explicit-Save form on the right -- and
 * the same Mad-Libs sentence builder for structure_effects that AdminCards
 * uses for card_effects, because the two tables were built to mirror each
 * other column for column (see 0057_structures.sql's header). A structure
 * has no Stats/Abilities split: everything about one lives on one form,
 * since there is no legacy compiler here to keep separate from the rest.
 *
 * IN ENGLISH ONLY, and with its own Save button, for exactly the reasons
 * AdminCards.tsx's own header gives for both.
 */

const BLANK: Omit<Structure, 'id'> = {
  slug: '', name: '', hp: 10, blocks_movement: false,
  accent: '#8a5a44', art_url: null, is_active: true, sort: 99,
}

// The developer's spec for Structures: the same sentence-builder logic as
// cards, with "stepped on" / "destroyed" / "invoker" among the relevant
// categories -- see structures_effects' trigger/target_selector check
// constraints in 0057_structures.sql for the source of every value below.
const TRIGGERS: StructureEffect['trigger'][] = [
  'ON_STEPPED_ON', 'ON_DESTROYED', 'ON_PLACE', 'PASSIVE',
]
// 0059: human-readable pill text for every trigger/target/status/condition
// field/duration option, same "Mad-Libs should never show a raw constant"
// pass AdminCards.tsx got. Kept as its own local map rather than a shared
// import, the same way every other vocabulary constant in this file
// already duplicates AdminCards.tsx's rather than importing it.
const TRIGGER_LABELS: Record<string, string> = {
  ON_STEPPED_ON: 'is stepped on',
  ON_DESTROYED: 'is destroyed',
  ON_PLACE: 'is placed',
  PASSIVE: 'is on the field',
}
const triggerLabel = (t: string) => TRIGGER_LABELS[t] ?? t
const TARGETS: StructureEffect['target_selector'][] = [
  'INVOKER', 'WHOEVER_STEPPED', 'ALL_ALLIES', 'ALL_ENEMIES', 'NEARBY_ALLIES',
  'ADJACENT_UNITS', 'NEAREST_ENEMY', 'LOWEST_HP_ENEMY', 'HIGHEST_HP_ENEMY',
  'LOWEST_HP_ALLY', 'HIGHEST_HP_ALLY', 'RANDOM_ENEMY_IN_RANGE', 'RANDOM_ALLY',
  'ALLIES_IN_LINE', 'ENEMIES_IN_LINE',
]
const TARGET_LABELS: Record<string, string> = {
  INVOKER: 'whoever triggered this',
  WHOEVER_STEPPED: 'whoever stepped on it',
  ALL_ALLIES: 'all allies',
  ALL_ENEMIES: 'all enemies',
  NEARBY_ALLIES: 'nearby allies',
  ADJACENT_UNITS: 'adjacent units',
  NEAREST_ENEMY: 'the nearest enemy',
  LOWEST_HP_ENEMY: 'the lowest-HP enemy',
  HIGHEST_HP_ENEMY: 'the highest-HP enemy',
  LOWEST_HP_ALLY: 'the lowest-HP ally',
  HIGHEST_HP_ALLY: 'the highest-HP ally',
  RANDOM_ENEMY_IN_RANGE: 'a random enemy in range',
  RANDOM_ALLY: 'a random ally',
  ALLIES_IN_LINE: 'allies in a line',
  ENEMIES_IN_LINE: 'enemies in a line',
}
const targetLabel = (t: string) => TARGET_LABELS[t] ?? t
const ACTIONS: StructureEffect['action'][] = [
  'DEAL_DAMAGE', 'HEAL', 'APPLY_STATUS', 'MODIFY_STAT', 'PUSH_BACK',
  'REMOVE_STATUS', 'GRANT_EXTRA_ACTIVATION',
  // 0058: a structure counter-attacking whoever destroys it -- documented
  // no-op, same bucket AdminCards.tsx keeps for REVIVE/etc. See
  // 0058_parry_vocabulary.sql's header for why TRIGGER_PARRY/IS_PARRIED are
  // NOT offered here: a structure never stands in cn_attack's swing loop.
  'COUNTER_ATTACK_PCT',
]
// 0058: the first no-op action a structure has ever had -- every action
// offered here before this was real, so there was nothing for a set like
// AdminCards.tsx's ACTION_NOOPS to do until now.
const ACTION_NOOPS = new Set<StructureEffect['action']>(['COUNTER_ATTACK_PCT'])
// Same label, same reasoning, as AdminCards.tsx's ACTION_LABELS -- kept as
// its own small local map rather than a shared import/export, the same way
// every other vocabulary constant in this file (TRIGGERS, ACTIONS,
// STAT_NAMES...) already duplicates AdminCards.tsx's rather than importing
// it, even where the two lists overlap.
const ACTION_LABELS: Record<string, string> = {
  DEAL_DAMAGE: 'deals damage to',
  HEAL: 'heals',
  APPLY_STATUS: 'applies status',
  MODIFY_STAT: 'modifies stat of',
  PUSH_BACK: 'pushes back',
  REMOVE_STATUS: 'removes status from',
  GRANT_EXTRA_ACTIVATION: 'grants an extra activation to',
  COUNTER_ATTACK_PCT: 'counter-attacks % damage to',
}
const actionLabel = (a: string) => ACTION_LABELS[a] ?? a
const STATUSES: NonNullable<StructureEffect['status']>[] = [
  'NONE', 'BURNING', 'STUN', 'POISON', 'ANY', 'ALL',
]
const STATUS_LABELS: Record<string, string> = {
  NONE: 'no status', BURNING: 'Burning', STUN: 'Stunned', POISON: 'Poisoned',
  ANY: 'any status', ALL: 'every status',
}
const statusLabel = (st: string) => STATUS_LABELS[st] ?? st
// The same vocabulary card_effects offers MODIFY_STAT/COPY_STAT_FROM_TARGET
// -- cn_effect_apply_action's v_num_field_map/v_bool_field_map (0049) are
// what actually reads these, and cn_run_structure_effects (0057) calls that
// SAME function, so every name it recognises there it recognises here. No
// "(runtime only)" split like AdminCards': every structure trigger already
// fires against a live match, there is no PASSIVE compiler for structures
// to collide with the way there is for cards.
const STAT_NAMES = [
  'SLIPPERY', 'TWICE_PCT', 'LIFESTEAL_PCT', 'PARRY_ALL', 'REGEN_PCT',
  'STUNS_ON_HIT', 'POISONS_ADJACENT', 'VS_POISONED_BONUS', 'CURES_BURN',
  'BLOOMS', 'SNEAKS', 'FLIES', 'TRAMPLES', 'PARRIES', 'BURNS', 'HEALS',
  'SWAMPS', 'HP', 'MOV', 'RMIN', 'RMAX', 'CRMIN', 'CRMAX', 'POWER',
  'PARRY_PCT', 'CRIT_PCT',
  // 0059: a structure can grant EVASION_PCT the same way it already grants
  // TWICE_PCT/REGEN_PCT -- v_num_field_map (cn_effect_apply_action) reads
  // it, cn_run_structure_effects calls that same function, so this needed
  // no engine change at all, only offering it here.
  'EVASION_PCT',
] as const
// 0059: every stat name this builder offers. Unlike AdminCards.tsx's own
// map, SLIPPERY and FLIES DO get labels here and are NOT removed from
// STAT_NAMES above -- for a structure they mean something else entirely:
// patching a unit's live runtime snapshot for as long as the effect lasts,
// not a card's own base stat, so pulling a unit's own ability out of the
// Cards builder (what Jared actually asked for) says nothing about
// whether a structure should still be able to grant it temporarily.
const STAT_NAME_LABELS: Record<string, string> = {
  SLIPPERY: "cannot be parried, and never takes a crit",
  TWICE_PCT: 'chance to strike twice %',
  LIFESTEAL_PCT: 'lifesteal %',
  PARRY_ALL: 'always parries',
  REGEN_PCT: 'regeneration % per turn',
  STUNS_ON_HIT: 'stuns on hit',
  POISONS_ADJACENT: 'poisons adjacent units',
  VS_POISONED_BONUS: 'bonus damage vs poisoned targets',
  CURES_BURN: 'also cures burning when healing',
  BLOOMS: 'heals spread to nearby allies too',
  SNEAKS: 'cannot be countered',
  FLIES: 'can fly (class trait)',
  TRAMPLES: 'tramples trees',
  PARRIES: 'counters before being hit',
  BURNS: 'burns on hit',
  HEALS: 'heals instead of attacking',
  SWAMPS: "silences nearby units' abilities",
  EVASION_PCT: 'evasion % (dodges the attack entirely)',
  HP: 'HP', MOV: 'Move', RMIN: 'min range', RMAX: 'max range',
  CRMIN: 'min counter range', CRMAX: 'max counter range', POWER: 'power',
  PARRY_PCT: 'parry %', CRIT_PCT: 'crit %',
}
const statNameLabel = (st: string) => STAT_NAME_LABELS[st] ?? st
// Mirrors cn_effect_condition_met (0049), which cn_run_structure_effects'
// own condition check (0057) also calls -- see AdminCards.tsx's identical
// constant for why these are the only fields offered.
const CONDITION_FIELDS = [
  'self.hp_pct', 'target.hp_pct',
  // 0059: the flat siblings -- "< 20" as much as "< 50%". See
  // cn_effect_condition_met's own comment for the (structurally identical,
  // un-normalised) branch that reads these.
  'self.hp', 'target.hp',
  'self.role', 'target.role',
  'self.has_status', 'target.has_status', 'roll_pct', 'turn_number',
  'is_royal_target', 'units_adjacent_count',
] as const
// 0059: every condition field -- same text AdminCards.tsx's identical map
// uses, since these are the same fields with the same meaning.
const CONDITION_FIELD_LABELS: Record<string, string> = {
  'self.hp_pct': "this structure's HP %",
  'target.hp_pct': "target's HP %",
  'self.hp': "this structure's HP",
  'target.hp': "target's HP",
  'self.role': "this structure's class",
  'target.role': "target's class",
  'self.has_status': 'this structure has status',
  'target.has_status': 'target has status',
  roll_pct: 'random roll %',
  turn_number: 'turn number',
  is_royal_target: 'target is royal',
  units_adjacent_count: 'units adjacent',
}
const conditionFieldLabel = (f: string) => CONDITION_FIELD_LABELS[f] ?? f
const CONDITION_OPS = ['=', '!=', '<', '<=', '>', '>=', 'in'] as const
const DURATIONS: NonNullable<StructureEffect['duration_kind']>[] = ['THIS_TURN', 'FOR_TURNS', 'UNTIL_REMOVED']
// 0059: every duration option -- same text AdminCards.tsx's identical map
// uses.
const DURATION_LABELS: Record<string, string> = {
  THIS_TURN: 'this turn',
  FOR_TURNS: 'for a number of turns',
  UNTIL_REMOVED: 'until removed',
}
const durationLabel = (d: string) => DURATION_LABELS[d] ?? d

const STRUCTURE_VOCAB: SentenceVocab = {
  triggers: TRIGGERS,
  triggerLabel,
  targets: TARGETS,
  targetLabel,
  // No Range category: structure_effects carries no range_kind/range_min/
  // range_max columns at all -- a structure's own "range" question is
  // already answered by ITS trigger (ON_STEPPED_ON reaches whoever is
  // standing on it; the rest reach outward from where it stands), so
  // Range would be an authoring control with nothing underneath it to
  // save. See this migration's header.
  ranges: [],
  actions: ACTIONS,
  actionNoops: ACTION_NOOPS,
  actionLabel,
  statuses: STATUSES,
  statusLabel,
  statNames: STAT_NAMES,
  statNameLabel,
  conditionFields: CONDITION_FIELDS,
  conditionFieldLabel,
  conditionOps: CONDITION_OPS,
  durations: DURATIONS,
  durationLabel,
}

let nextTempId = 1
function newGroupId(): string {
  return (typeof crypto !== 'undefined' && crypto.randomUUID)
    ? crypto.randomUUID()
    : `g-${nextTempId++}-${Date.now()}`
}
function blankEffect(structureId: string, sort: number, groupId?: string): StructureEffect {
  return {
    id: `new-${nextTempId++}`, structure_id: structureId, sort, group_id: groupId ?? newGroupId(),
    trigger: 'ON_STEPPED_ON', target_selector: 'WHOEVER_STEPPED', action: 'APPLY_STATUS',
    value: null, status: 'POISON', stat_name: null, conditions: [],
    duration_kind: null, duration_turns: null,
  }
}

export function AdminStructures() {
  const [rows, setRows] = useState<Structure[]>([])
  const [openId, setOpenId] = useState<string | null>(null)
  const [draft, setDraft] = useState<Structure | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)

  const [effects, setEffects] = useState<StructureEffect[]>([])
  const [effectsBusy, setEffectsBusy] = useState(false)
  const [effectsErr, setEffectsErr] = useState<string | null>(null)
  const [effectsNote, setEffectsNote] = useState<string | null>(null)

  const loadEffects = useCallback(async (structureId: string) => {
    if (structureId === 'new') { setEffects([]); return }
    const { data, error } = await supabase.from('structure_effects')
      .select('*').eq('structure_id', structureId).order('sort')
    if (error) { setEffectsErr(error.message); return }
    setEffects((data ?? []) as StructureEffect[])
  }, [])

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('structures').select('*').order('sort')
    if (error) { setErr(error.message); return }
    setRows((data ?? []) as Structure[])
  }, [])
  useEffect(() => { void load() }, [load])

  function open(r: Structure) {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenId(r.id); setDraft({ ...r })
    setEffectsErr(null); setEffectsNote(null)
    void loadEffects(r.id)
  }
  function blank() {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenId('new'); setDraft({ id: 'new', ...BLANK })
    setEffects([]); setEffectsErr(null); setEffectsNote(null)
  }
  const set = (patch: Partial<Structure>) => setDraft((d) => (d ? { ...d, ...patch } : d))

  function groupIdOf(e: StructureEffect): string {
    return e.group_id || e.id
  }
  function onAddSentence() {
    if (!draft) return
    setEffects((es) => [...es, blankEffect(draft.id, es.length)])
  }
  function onAddClause(groupId: string) {
    if (!draft) return
    setEffects((es) => {
      const first = es.find((e) => groupIdOf(e) === groupId)
      const row = blankEffect(draft.id, es.length, groupId)
      if (first) { row.trigger = first.trigger; row.conditions = first.conditions }
      return [...es, row]
    })
  }
  function onChangeRow(rowId: string, patch: Partial<SentenceRow>) {
    setEffects((es) => es.map((e) => (e.id === rowId ? { ...e, ...(patch as Partial<StructureEffect>) } : e)))
  }
  function onRemoveRow(rowId: string) {
    setEffects((es) => {
      const target = es.find((e) => e.id === rowId)
      if (!target) return es
      const gid = groupIdOf(target)
      if (es.filter((e) => groupIdOf(e) === gid).length <= 1) return es
      return es.filter((e) => e.id !== rowId)
    })
  }
  function onSetTrigger(groupId: string, trigger: string) {
    setEffects((es) => es.map((e) => (
      groupIdOf(e) === groupId ? { ...e, trigger: trigger as StructureEffect['trigger'] } : e
    )))
  }
  function onSetConditions(groupId: string, conditions: StructureEffect['conditions']) {
    setEffects((es) => es.map((e) => (groupIdOf(e) === groupId ? { ...e, conditions } : e)))
  }
  function onRemoveSentence(groupId: string) {
    setEffects((es) => es.filter((e) => groupIdOf(e) !== groupId))
  }

  /** Same delete-then-reinsert reasoning as AdminCards.tsx's saveEffects:
   *  nothing else references a structure_effects row by id, so replacing
   *  the whole set is exactly as correct as patching it and much simpler. */
  async function saveEffects() {
    if (!draft || draft.id === 'new') return
    setEffectsBusy(true); setEffectsErr(null); setEffectsNote(null)
    const { error: delErr } = await supabase.from('structure_effects').delete().eq('structure_id', draft.id)
    if (delErr) { setEffectsBusy(false); setEffectsErr(delErr.message); return }
    if (effects.length) {
      const body = effects.map((e, i) => ({
        structure_id: draft.id, sort: i, group_id: e.group_id, trigger: e.trigger,
        target_selector: e.target_selector, action: e.action, value: e.value ?? null,
        status: e.status ?? null, stat_name: e.stat_name ?? null, conditions: e.conditions,
        duration_kind: e.duration_kind ?? null, duration_turns: e.duration_turns ?? null,
      }))
      const { error: insErr } = await supabase.from('structure_effects').insert(body)
      if (insErr) { setEffectsBusy(false); setEffectsErr(insErr.message); return }
    }
    setEffectsBusy(false)
    setEffectsNote('Saved.')
    await loadEffects(draft.id)
  }

  async function save() {
    if (!draft) return
    setBusy(true); setErr(null); setNote(null)
    const { id, ...body } = draft
    const q = id === 'new'
      ? supabase.from('structures').insert(body).select('*').single()
      : supabase.from('structures').update(body).eq('id', id).select('*').single()
    const { data, error } = await q
    setBusy(false)
    if (error) { setErr(error.message.replace(/^.*?:\s*/, '')); return }
    const row = data as Structure
    setNote(`Saved ${row.name}.`)
    setOpenId(row.id); setDraft({ ...row })
    void load()
  }

  /** admin_delete_structure() (0057) refuses while the slug is standing as
   *  an obstacle in any unfinished match -- the same "not while it is live
   *  somewhere" guard admin_delete_card() already enforces for cards. */
  async function deleteForever() {
    if (!draft || draft.id === 'new') return
    setBusy(true); setErr(null); setNote(null)
    try {
      await adminDeleteStructure(draft.id)
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
        <button className="btn small" onClick={blank}>New structure</button>
        {rows.map((r) => (
          <button
            key={r.id} type="button"
            className={`admin-row${r.id === openId ? ' is-open' : ''}` +
                       `${r.is_active ? '' : ' is-retired'}`}
            onClick={() => open(r)}
          >
            <span className="admin-swatch" style={{ background: r.accent ?? '#8a5a44' }} aria-hidden="true" />
            <span className="admin-rowname">{r.name || r.slug || '(no name)'}</span>
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
            <label><span>HP</span>
              <input
                type="number" value={draft.hp ?? 0}
                onChange={(e) => set({ hp: Number(e.target.value) })}
              />
            </label>
            <label><span>Sort</span>
              <input
                type="number" value={draft.sort ?? 0}
                onChange={(e) => set({ sort: Number(e.target.value) })}
              />
            </label>
            <label className="admin-colour"><span>Accent</span>
              <input
                type="color" value={/^#[0-9a-fA-F]{6}$/.test(draft.accent ?? '') ? (draft.accent as string) : '#8a5a44'}
                onChange={(e) => set({ accent: e.target.value })}
              />
              <input
                className="admin-hex" value={draft.accent ?? ''}
                onChange={(e) => set({ accent: e.target.value })}
              />
            </label>
            <label className="admin-wide"><span>
              Art URL — relative to the site root, e.g. structures/spike-trap.webp.
              Uploaded separately in Storage; there is no picker here yet.
            </span>
              <input
                value={draft.art_url ?? ''}
                onChange={(e) => set({ art_url: e.target.value || null })}
              />
            </label>
          </div>

          <label className="admin-flag admin-wide">
            <input
              type="checkbox" checked={draft.blocks_movement}
              onChange={(e) => set({ blocks_movement: e.target.checked })}
            />
            <span>
              Blocks movement and line of sight, like a wall -- unticked, it is
              walked onto and shot over, like a trap.
            </span>
          </label>

          <label className="admin-flag admin-wide">
            <input
              type="checkbox" checked={draft.is_active}
              onChange={(e) => set({ is_active: e.target.checked })}
            />
            <span>
              In the game. Unticking retires it: no card can newly place one,
              and admin_delete_structure still refuses to remove the row while
              it stands in any unfinished match. Nothing already placed is
              affected.
            </span>
          </label>

          <div className="admin-wide">
            <h3 className="sb-heading">What it does</h3>
            {draft.id === 'new' ? (
              <p className="muted">
                Save this structure once before giving it any effects -- a row
                here needs a structure to belong to.
              </p>
            ) : (
              <div className="admin-effects">
                <SentenceBuilder
                  vocab={STRUCTURE_VOCAB}
                  groups={groupSentences(effects)}
                  sentenceNoun="effect"
                  onChangeRow={onChangeRow}
                  onRemoveRow={onRemoveRow}
                  onAddClause={onAddClause}
                  onSetTrigger={onSetTrigger}
                  onSetConditions={onSetConditions}
                  onAddSentence={onAddSentence}
                  onRemoveSentence={onRemoveSentence}
                />
                <div className="actionbar admin-acts">
                  <button type="button" className="btn primary" disabled={effectsBusy} onClick={() => void saveEffects()}>
                    {effectsBusy ? 'Saving…' : 'Save effects'}
                  </button>
                  {effectsNote && <span className="savemark">{effectsNote}</span>}
                </div>
                {effectsErr && <p className="error">{effectsErr}</p>}
              </div>
            )}
          </div>

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
        </form>
      )}
    </div>
  )
}
