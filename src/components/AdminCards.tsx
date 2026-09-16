import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { adminDeleteCard } from '../lib/api'
import { artUrl, faceUrl } from '../lib/art'
import type { Card, CardEffect } from '../lib/types'
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

// Since 0049/0050: everything that USED to be a raw checkbox here except
// `royal` and `flies` is now a PASSIVE/MODIFY_STAT row on the "Abilities &
// Passives" tab below (parry_all, parries, burns, heals, cures, sneaks,
// tramples, blooms) -- see cn_compile_card_effects. `royal` and `flies` stay
// here because neither is compiler-owned: `royal` is a structural fact
// cn_check_card enforces (one crown per kingdom) and `flies` is derived from
// `role` by that same trigger on every write, so a card_effects row for
// either would just be silently overwritten. LEAVING THE OTHER EIGHT HERE
// TOO WOULD BE A REAL BUG, not merely a redundant control: the compiler
// RESETS every column it owns to false and re-derives it from card_effects
// rows every time ANY row for this card changes (see that function's own
// comment), so a raw checkbox edit made here would be silently reverted the
// next time the Abilities tab saved anything for the same card -- two
// sources of truth for one column, and the newer write always loses.
const FLAGS = [
  ['royal', 'Royal'], ['flies', 'Flies'],
] as const

// The full soft-coded vocabulary, since 0049 -- see
// supabase/migrations/0049_card_effects_engine.sql's header and the
// card_effects table's own column comments for what each one means and, for
// everything past the developer's original list, why it was added.
const TRIGGERS: CardEffect['trigger'][] = [
  'ON_PLAY', 'ON_ABILITY', 'ON_ATTACK', 'ON_DEATH', 'START_OF_TURN',
  'END_OF_TURN', 'ON_PARRY', 'PASSIVE',
  'ON_COUNTER', 'ON_KILL', 'ON_HEALED', 'ON_DAMAGED', 'ON_STATUS_APPLIED',
]
const TARGETS: CardEffect['target_selector'][] = [
  'SELF', 'NEARBY_ALLIES', 'ALL_ALLIES', 'ENEMY_IN_RANGE', 'LOWEST_HP_ENEMY',
  'BOARD_CELL', 'ALL_ENEMIES', 'NEAREST_ENEMY', 'HIGHEST_HP_ENEMY',
  'LOWEST_HP_ALLY', 'HIGHEST_HP_ALLY', 'RANDOM_ENEMY_IN_RANGE', 'RANDOM_ALLY',
  'ALLIES_IN_LINE', 'ENEMIES_IN_LINE', 'THE_ATTACKER', 'THE_TARGET',
  'ADJACENT_UNITS',
]
const ACTIONS: CardEffect['action'][] = [
  'DEAL_DAMAGE', 'HEAL', 'APPLY_STATUS', 'MODIFY_STAT', 'PUSH_BACK',
  'DRAW_CARD', 'REMOVE_STATUS', 'GRANT_EXTRA_ACTIVATION', 'SUMMON_OBJECT',
  'TELEPORT_SELF', 'SWAP_POSITIONS', 'REVIVE', 'COPY_STAT_FROM_TARGET',
  'REFLECT_DAMAGE_PCT',
]
// REVIVE, REFLECT_DAMAGE_PCT, SUMMON_OBJECT and DRAW_CARD are accepted by the
// schema for a complete authoring vocabulary but are documented no-ops in
// cn_effect_apply_action -- see that function's own comment for exactly why
// each one is left unbuilt. Flagged here rather than hidden, so picking one
// tells you the truth instead of silently doing nothing.
const ACTION_NOOPS = new Set<CardEffect['action']>([
  'REVIVE', 'REFLECT_DAMAGE_PCT', 'SUMMON_OBJECT', 'DRAW_CARD',
])
const STATUSES: NonNullable<CardEffect['status']>[] = [
  'NONE', 'BURNING', 'STUN', 'POISON', 'ANY', 'ALL',
]
const STAT_NAMES = [
  'SLIPPERY', 'TWICE_PCT', 'LIFESTEAL_PCT', 'PARRY_ALL', 'REGEN_PCT',
  'STUNS_ON_HIT', 'POISONS_ADJACENT', 'VS_POISONED_BONUS', 'CURES_BURN',
  'BLOOMS', 'SNEAKS', 'FLIES', 'TRAMPLES', 'PARRIES', 'BURNS', 'HEALS',
  'SWAMPS',
  'AURA_RESIST_KNIGHT', 'AURA_RESIST_ROGUE', 'AURA_RESIST_MAGE', 'AURA_RESIST_FLYING',
  'AURA_BONUS_KNIGHT', 'AURA_BONUS_ROGUE', 'AURA_BONUS_MAGE', 'AURA_BONUS_FLYING',
  'AURA_RESIST_EFFECTS',
  // RUNTIME-only -- meaningful as a MODIFY_STAT fired from ON_ABILITY/
  // ON_ATTACK/etc against a live match's unit snapshot. The PASSIVE compiler
  // silently ignores these nine on a PASSIVE row -- see
  // cn_compile_card_effects's own comment for why writing them from a
  // passive would double-count or be clobbered by cn_check_card.
  'HP', 'MOV', 'RMIN', 'RMAX', 'CRMIN', 'CRMAX', 'POWER', 'PARRY_PCT', 'CRIT_PCT',
] as const
const RUNTIME_ONLY_STATS = new Set([
  'HP', 'MOV', 'RMIN', 'RMAX', 'CRMIN', 'CRMAX', 'POWER', 'PARRY_PCT', 'CRIT_PCT',
])
// Every field cn_effect_condition_met (0049) knows how to read, so a
// condition built here is guaranteed to mean something on the server rather
// than silently evaluating to "true" (that function's own fallback for a
// field it does not recognise).
const CONDITION_FIELDS = [
  'self.hp_pct', 'target.hp_pct', 'self.role', 'target.role',
  'self.has_status', 'target.has_status', 'roll_pct', 'turn_number',
  'is_royal_target', 'units_adjacent_count',
] as const
const CONDITION_OPS = ['=', '!=', '<', '<=', '>', '>=', 'in'] as const

/** A brand-new row this screen is building, before it has a database id.
 *  Given one here rather than left undefined so React has a stable key and
 *  saveEffects() can tell "already in the table" from "not yet" without a
 *  second array to track it in. */
let nextTempId = 1
function blankEffect(cardId: string, sort: number): CardEffect {
  return {
    id: `new-${nextTempId++}`, card_id: cardId, sort,
    trigger: 'PASSIVE', target_selector: 'SELF', action: 'MODIFY_STAT',
    value: null, status: null, stat_name: 'SLIPPERY', conditions: [],
  }
}

export function AdminCards() {
  const [rows, setRows] = useState<Row[]>([])
  const [openId, setOpenId] = useState<string | null>(null)
  const [draft, setDraft] = useState<Row | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  // Since 0046: the id of the card this screen is asking "really delete
  // this?" about -- the same two-step shape AdminUsers.tsx uses for
  // confirmBan, reused here rather than reinvented.
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)

  // Since 0049: Stats vs Abilities & Passives. A card's identity (slug/name/
  // role/accent) sits above both, because it belongs to neither one alone.
  const [formTab, setFormTab] = useState<'stats' | 'abilities'>('stats')
  const [effects, setEffects] = useState<CardEffect[]>([])
  const [effectsBusy, setEffectsBusy] = useState(false)
  const [effectsErr, setEffectsErr] = useState<string | null>(null)
  const [effectsNote, setEffectsNote] = useState<string | null>(null)

  const loadEffects = useCallback(async (cardId: string) => {
    if (cardId === 'new') { setEffects([]); return }
    const { data, error } = await supabase.from('card_effects')
      .select('*').eq('card_id', cardId).order('sort')
    if (error) { setEffectsErr(error.message); return }
    setEffects((data ?? []) as CardEffect[])
  }, [])

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('cards').select('*').order('sort')
    if (error) { setErr(error.message); return }
    setRows((data ?? []) as Row[])
  }, [])
  useEffect(() => { void load() }, [load])

  function open(r: Row) {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenId(r.id); setDraft({ ...r })
    setFormTab('stats'); setEffectsErr(null); setEffectsNote(null)
    void loadEffects(r.id)
  }
  function blank() {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenId('new'); setDraft({ id: 'new', ...BLANK })
    setFormTab('stats'); setEffects([]); setEffectsErr(null); setEffectsNote(null)
  }
  const set = (patch: Partial<Row>) => setDraft((d) => (d ? { ...d, ...patch } : d))

  function addEffect() {
    if (!draft) return
    setEffects((es) => [...es, blankEffect(draft.id, es.length)])
  }
  function setEffectAt(idx: number, patch: Partial<CardEffect>) {
    setEffects((es) => es.map((e, i) => (i === idx ? { ...e, ...patch } : e)))
  }
  function removeEffectAt(idx: number) {
    setEffects((es) => es.filter((_, i) => i !== idx))
  }
  function addCondition(idx: number) {
    setEffectAt(idx, {
      conditions: [...(effects[idx]?.conditions ?? []), { field: CONDITION_FIELDS[0], op: '=', value: '' }],
    })
  }
  function setConditionAt(idx: number, cIdx: number, patch: Partial<CardEffect['conditions'][number]>) {
    const row = effects[idx]
    if (!row) return
    setEffectAt(idx, {
      conditions: row.conditions.map((c: CardEffect['conditions'][number], i: number) => (i === cIdx ? { ...c, ...patch } : c)),
    })
  }
  function removeConditionAt(idx: number, cIdx: number) {
    const row = effects[idx]
    if (!row) return
    setEffectAt(idx, { conditions: row.conditions.filter((_: CardEffect['conditions'][number], i: number) => i !== cIdx) })
  }

  /**
   * Explicit Save, same as the card row's own -- no autosave here either.
   * Delete-then-reinsert rather than a diff: card_effects rows carry nothing
   * anything else references (no kingdom, no match, no foreign key aims at
   * one), so replacing the whole set for this card in one go is exactly as
   * correct as patching it row by row and a great deal simpler. Each write
   * fires cn_compile_card_effects_trg (0049), which re-derives every legacy
   * passive column on `cards` from what is left when this finishes.
   */
  async function saveEffects() {
    if (!draft || draft.id === 'new') return
    setEffectsBusy(true); setEffectsErr(null); setEffectsNote(null)
    const { error: delErr } = await supabase.from('card_effects').delete().eq('card_id', draft.id)
    if (delErr) { setEffectsBusy(false); setEffectsErr(delErr.message); return }
    if (effects.length) {
      const body = effects.map((e, i) => ({
        card_id: draft.id, sort: i, trigger: e.trigger, target_selector: e.target_selector,
        action: e.action, value: e.value ?? null, status: e.status ?? null,
        stat_name: e.stat_name ?? null, conditions: e.conditions,
      }))
      const { error: insErr } = await supabase.from('card_effects').insert(body)
      if (insErr) { setEffectsBusy(false); setEffectsErr(insErr.message); return }
    }
    setEffectsBusy(false)
    setEffectsNote('Saved.')
    await loadEffects(draft.id)
    // The compiler just re-derived slippery/twice_pct/etc on `cards` from
    // what was saved above -- the same cache invalidation save() does, for
    // the same reason: every other screen's cached roster is now stale.
    clearCards()
    void load()
  }

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

  /**
   * The real delete, since 0046 -- see admin_delete_card() in
   * 0046_admin_content_and_delete.sql for every check the server makes
   * before it lets the row go: retired first, not in anyone's deck or
   * kingdom, not on the board in a match that has not finished. This screen
   * shows whatever sentence comes back rather than a generic "could not
   * delete" -- the same treatment save()'s errors get.
   *
   * Storage cleanup happens AFTER the row is gone, and only if it is: the
   * art and audio objects under this slug are not referenced by anything
   * once the row is deleted, but they are not gameplay-critical either, so a
   * failed or interrupted cleanup call here leaves orphaned files rather
   * than a half-deleted card -- see cleanupCardStorage() below and the
   * report for that tradeoff.
   */
  async function deleteForever() {
    if (!draft || draft.id === 'new') return
    setBusy(true); setErr(null); setNote(null)
    try {
      await adminDeleteCard(draft.id)
      await cleanupCardStorage(draft)
      setNote(`Deleted ${draft.name || draft.slug} permanently.`)
      setConfirmDelete(null); setOpenId(null); setDraft(null)
      clearCards()
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

          {/* Since 0049: Stats stays exactly what it always was. Abilities &
              Passives is the new soft-coded editor -- see AdminCards's own
              header comment on FLAGS for why eight of the old checkboxes
              moved here instead of just gaining neighbours. */}
          <div className="admin-wide admintabs">
            <button
              type="button" className={`btn small ${formTab === 'stats' ? 'primary' : 'ghost'}`}
              onClick={() => setFormTab('stats')}
            >
              Stats
            </button>
            <button
              type="button" className={`btn small ${formTab === 'abilities' ? 'primary' : 'ghost'}`}
              onClick={() => setFormTab('abilities')}
            >
              Abilities &amp; Passives
            </button>
          </div>

          {formTab === 'stats' && (
            <>
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
            </>
          )}

          {formTab === 'abilities' && (
            <AbilityEditor
              cardId={draft.id}
              effects={effects}
              busy={effectsBusy}
              err={effectsErr}
              note={effectsNote}
              onAdd={addEffect}
              onChange={setEffectAt}
              onRemove={removeEffectAt}
              onAddCondition={addCondition}
              onChangeCondition={setConditionAt}
              onRemoveCondition={removeConditionAt}
              onSave={() => void saveEffects()}
            />
          )}

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
            {/* Delete permanently -- only once a card is already retired.
                Retiring stays the normal, reversible way to take a card out
                of the game; this is the second, harder-to-reach step for a
                test/mistake row that was never meant to come back. */}
            {draft.id !== 'new' && !draft.is_active && (
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

/**
 * The soft-coded ability/passive editor, since 0049. One row is one
 * card_effects row: trigger + target + action, with value/status/stat_name
 * shown only where the chosen action needs them (the same NOT NULL checks
 * the table itself enforces -- see card_effects_status_action_needs_status
 * and card_effects_modify_stat_needs_name), plus an optional list of
 * conditions.
 *
 * ITS OWN SAVE BUTTON, same reasoning as the card row's: this table is read
 * by cn_army the moment ANY match starts a new army, and a half-typed value
 * should not be live before Save is pressed.
 *
 * A brand-new, not-yet-saved card has no id for these rows to point at, so
 * the tab says that plainly instead of pretending to be usable.
 */
function AbilityEditor({
  cardId, effects, busy, err, note, onAdd, onChange, onRemove,
  onAddCondition, onChangeCondition, onRemoveCondition, onSave,
}: {
  cardId: string
  effects: CardEffect[]
  busy: boolean
  err: string | null
  note: string | null
  onAdd: () => void
  onChange: (idx: number, patch: Partial<CardEffect>) => void
  onRemove: (idx: number) => void
  onAddCondition: (idx: number) => void
  onChangeCondition: (idx: number, cIdx: number, patch: Partial<CardEffect['conditions'][number]>) => void
  onRemoveCondition: (idx: number, cIdx: number) => void
  onSave: () => void
}) {
  if (cardId === 'new') {
    return (
      <p className="muted admin-wide">
        Save this card once, on the Stats tab, before giving it any abilities
        or passives -- a row here needs a card to belong to.
      </p>
    )
  }

  return (
    <div className="admin-wide admin-effects">
      {effects.length === 0 && (
        <p className="muted">
          Nothing yet. This card has no ability and no passive beyond what its
          role gives every card of that class.
        </p>
      )}
      {effects.map((row, idx) => {
        const needsStatus = row.action === 'APPLY_STATUS' || row.action === 'REMOVE_STATUS'
        const needsStat = row.action === 'MODIFY_STAT' || row.action === 'COPY_STAT_FROM_TARGET'
        return (
          <div key={row.id} className="admin-effectrow">
            <div className="admin-effectgrid">
              <label><span>Trigger</span>
                <select
                  value={row.trigger}
                  onChange={(e) => onChange(idx, { trigger: e.target.value as CardEffect['trigger'] })}
                >
                  {TRIGGERS.map((t) => <option key={t} value={t}>{t}</option>)}
                </select>
              </label>
              <label><span>Target</span>
                <select
                  value={row.target_selector}
                  onChange={(e) => onChange(idx, { target_selector: e.target.value as CardEffect['target_selector'] })}
                >
                  {TARGETS.map((t) => <option key={t} value={t}>{t}</option>)}
                </select>
              </label>
              <label><span>Action</span>
                <select
                  value={row.action}
                  onChange={(e) => onChange(idx, { action: e.target.value as CardEffect['action'] })}
                >
                  {ACTIONS.map((a) => (
                    <option key={a} value={a}>{a}{ACTION_NOOPS.has(a) ? ' (not built yet)' : ''}</option>
                  ))}
                </select>
              </label>
              <label><span>Value</span>
                <input
                  type="number" value={row.value ?? ''}
                  onChange={(e) => onChange(idx, { value: e.target.value === '' ? null : Number(e.target.value) })}
                />
              </label>
              {needsStatus && (
                <label><span>Status</span>
                  <select
                    value={row.status ?? ''}
                    onChange={(e) => onChange(idx, { status: (e.target.value || null) as CardEffect['status'] })}
                  >
                    <option value="">—</option>
                    {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
                  </select>
                </label>
              )}
              {needsStat && (
                <label><span>Stat</span>
                  <select
                    value={row.stat_name ?? ''}
                    onChange={(e) => onChange(idx, { stat_name: e.target.value || null })}
                  >
                    <option value="">—</option>
                    {STAT_NAMES.map((s) => (
                      <option key={s} value={s}>{s}{RUNTIME_ONLY_STATS.has(s) ? ' (runtime only)' : ''}</option>
                    ))}
                  </select>
                </label>
              )}
            </div>

            <div className="admin-conditions">
              <div className="admin-conditions-head">
                <span className="muted tiny">Only if (all must hold):</span>
                <button type="button" className="btn tiny ghost" onClick={() => onAddCondition(idx)}>
                  + Condition
                </button>
              </div>
              {row.conditions.map((c: CardEffect['conditions'][number], cIdx: number) => (
                <div key={cIdx} className="admin-conditionrow">
                  <select
                    value={c.field}
                    onChange={(e) => onChangeCondition(idx, cIdx, { field: e.target.value })}
                  >
                    {CONDITION_FIELDS.map((f) => <option key={f} value={f}>{f}</option>)}
                  </select>
                  <select
                    value={c.op ?? '='}
                    onChange={(e) => onChangeCondition(idx, cIdx, { op: e.target.value })}
                  >
                    {CONDITION_OPS.map((o) => <option key={o} value={o}>{o}</option>)}
                  </select>
                  <input
                    value={c.value ?? ''}
                    onChange={(e) => onChangeCondition(idx, cIdx, { value: e.target.value })}
                    placeholder="value"
                  />
                  <button
                    type="button" className="btn tiny ghost admin-effectdelete"
                    onClick={() => onRemoveCondition(idx, cIdx)}
                    aria-label="Remove condition"
                  >
                    ×
                  </button>
                </div>
              ))}
            </div>

            <button
              type="button" className="btn small danger admin-effectrow-delete"
              onClick={() => onRemove(idx)}
            >
              Delete this effect
            </button>
          </div>
        )
      })}

      <div className="actionbar admin-acts">
        <button type="button" className="btn ghost" onClick={onAdd}>+ Add effect</button>
        <button type="button" className="btn primary" disabled={busy} onClick={onSave}>
          {busy ? 'Saving…' : 'Save'}
        </button>
        {note && <span className="savemark">{note}</span>}
      </div>
      {err && <p className="error">{err}</p>}
    </div>
  )
}

/**
 * Best-effort cleanup of a deleted card's Storage objects, since 0046.
 *
 * plpgsql cannot reach Supabase Storage, so admin_delete_card() only removes
 * the row -- this runs client-side, after that call has already succeeded,
 * and never blocks or reverses the delete: the row is gone either way, and a
 * failed or interrupted call here just leaves an orphaned file under a slug
 * nothing points at any more, which costs storage but breaks nothing.
 *
 * The face crop always shares the full art's extension (see Art's `ext`
 * below and put()'s `useExt` for `which === 'face'`), so both art paths are
 * derived from art_url; each of the four audio kinds carries its own URL and
 * so its own extension.
 */
async function cleanupCardStorage(row: Row): Promise<void> {
  if (!row.slug) return
  try {
    const extOf = (url: string | null | undefined, fallback: string) => {
      const m = (url ?? '').match(/\.([a-z0-9]+)(?:\?|$)/i)
      return m ? m[1] : fallback
    }
    const artExt = extOf(row.art_url, 'webp')
    if (row.art_url) {
      await supabase.storage.from('art')
        .remove([`cards/${row.slug}.${artExt}`, `cards/${row.slug}-face.${artExt}`])
    }
    const audioPaths = (
      [
        ['audio_attack_url', 'attack'], ['audio_ability_url', 'ability'],
        ['audio_passive_url', 'passive'], ['audio_walk_url', 'walk'],
      ] as const
    )
      .filter(([col]) => row[col])
      .map(([col, kind]) => `cards/${row.slug}-${kind}.${extOf(row[col], 'mp3')}`)
    if (audioPaths.length) await supabase.storage.from('audio').remove(audioPaths)
  } catch (e) {
    // Storage cleanup is a courtesy, not a correctness requirement -- the
    // card is already gone from the database whether this succeeds or not.
    console.warn('cleanupCardStorage:', (e as Error).message)
  }
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
