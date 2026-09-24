import { useState, type ReactNode } from 'react'

/**
 * The "Mad Libs" sentence builder, since 0056/0057.
 *
 * Shared between AdminCards.tsx's Abilities & Passives tab and
 * AdminStructures.tsx's structure-effects tab -- the two screens' rows
 * (CardEffect / StructureEffect) already share the same trigger/
 * target_selector/action/value/status/stat_name/conditions/duration_kind/
 * duration_turns shape (card_effects and structure_effects were built to
 * mirror each other column for column -- see 0057's header), so one
 * component renders both, parameterised by SentenceVocab.
 *
 * WHAT "ADD BLOCK" MEANS HERE, and why this is not a fully free-form
 * grammar: the developer's spec describes clicking "Add Block" to append
 * "Connector, Target, Trigger, Action, etc" blocks in any arrangement. The
 * schema underneath is not that free -- one row is always exactly
 * trigger + [conditions] + target + action + (value/status/stat) +
 * duration, because that is what cn_run_effects/cn_run_structure_effects
 * actually read. So the sentence's SHAPE is fixed ("When X, if Y, then
 * target Z do W [for N turns], and target Z2 do W2..."), and what "Add
 * Block" does is append another clause -- another target+action pair
 * chained with "And", sharing the sentence's one trigger and condition
 * list. Every individual word IS a clickable pill that swaps its value via
 * a dropdown, which is the part of the spec that maps onto something the
 * engine can run.
 *
 * "Or" WAS accepted vocabulary but not built, as of 0049/0074 -- every
 * condition evaluated as AND, with no OR branch anywhere in the engine.
 * 0075 closes that gap with the "ALL/ANY grouping" method rather than an
 * inline "X and (Y or Z)" sentence with parentheses: a "+ If (group)"
 * button appends a labelled block --
 *   IF [ALL ▼] of the following are true: [condition] [condition] ...
 * -- that reads as its own clause rather than breaking the sentence's flow,
 * and switching the dropdown to ANY makes it an OR of its own children.
 * Nesting works because a group's own children are the SAME shape a
 * top-level condition list is: a group can hold another group, to any
 * depth (an ANY block inside an ALL block, or the reverse). See
 * ConditionGroupRow/ConditionNode below and cn_effect_node_met (0075) for
 * the server half -- no schema change was needed, since `conditions` was
 * already "an array, AND'd together"; a group is just a new shape one
 * array element can take.
 */

export interface ConditionRow {
  field: string
  op?: string
  value?: string
  /** 0074: flips this one condition's result before it enters the chain's
   *  AND -- see cn_effect_conditions_met's own comment for exactly where
   *  the flip happens. Every condition in the chain is still AND'd
   *  together; this only negates the individual term, so "if X and not Y"
   *  is expressible without a second, un-buildable OR/NOT-of-the-whole-
   *  chain control. Undefined reads the same as false -- an old row saved
   *  before this existed keeps meaning exactly what it always meant. */
  negate?: boolean
}

/**
 * A labelled ALL/ANY block, since 0075. `children` is ConditionNode[] --
 * the same union this file exports -- so a group can hold a plain leaf OR
 * another group, recursively: nesting is just this type being self-
 * referential, not a separate mechanism. `negate` mirrors ConditionRow's
 * own flag, extended to a whole group for free (not offered by any control
 * in this file today, but a group that COULD be negated and silently isn't
 * would be the same kind of quiet gap this project's own conventions call
 * out rather than leave undocumented).
 */
export interface ConditionGroupRow {
  kind: 'group'
  mode: 'ALL' | 'ANY'
  children: ConditionNode[]
  negate?: boolean
}

/** One node of a conditions tree: a leaf condition, or a nested ALL/ANY
 *  group. Mirrors types.ts's own ConditionNode -- duplicated rather than
 *  imported, the same way ConditionRow's shape is already duplicated in
 *  types.ts's CardEffect/StructureEffect rather than imported from here
 *  (this is a components/ file; types.ts is lib/, and lib does not import
 *  from components). */
export type ConditionNode = ConditionRow | ConditionGroupRow

export function isConditionGroup(n: ConditionNode): n is ConditionGroupRow {
  return (n as ConditionGroupRow).kind === 'group'
}

/** The common shape of one CardEffect or StructureEffect row, as far as this
 *  builder needs to know. Callers pass their real rows through (typed
 *  wider) and narrow the patches they get back with a cast -- see
 *  AdminCards.tsx/AdminStructures.tsx's own onChangeRow. */
export interface SentenceRow {
  id: string
  group_id?: string
  sort: number
  trigger: string
  target_selector: string
  action: string
  value?: number | null
  status?: string | null
  stat_name?: string | null
  conditions: ConditionNode[]
  duration_kind?: string | null
  duration_turns?: number | null
  range_kind?: string | null
  range_min?: number | null
  range_max?: number | null
  /** 0074: which row in `structures` CREATE_STRUCTURE/SUMMON_OBJECT places
   *  -- required by the schema for both actions (see
   *  card_effects_create_structure_needs_slug), so a row using either one
   *  needs this control, not just a value box. */
  structure_slug?: string | null
}

export interface SentenceGroup<T extends SentenceRow = SentenceRow> {
  groupId: string
  rows: T[]
}

/** Rows sharing a group_id are one authored sentence; a pre-0056 row with no
 *  group_id at all is its own one-row sentence, keyed by its own id -- see
 *  card_effects.group_id's column comment. Order is preserved: the first
 *  group encountered walking the flat array keeps its position. */
export function groupSentences<T extends SentenceRow>(rows: T[]): SentenceGroup<T>[] {
  const order: string[] = []
  const map = new Map<string, T[]>()
  for (const r of rows) {
    const gid = r.group_id || r.id
    if (!map.has(gid)) { map.set(gid, []); order.push(gid) }
    map.get(gid)!.push(r)
  }
  return order.map((groupId) => ({ groupId, rows: map.get(groupId)! }))
}

const NO_VALUE_ACTIONS = new Set([
  'REMOVE_STATUS', 'COPY_STAT_FROM_TARGET', 'SWAP_POSITIONS', 'TELEPORT_SELF',
  // 0074: REVIVE now DOES take a value -- see card_effects_revive_value_check
  // -- it is what percentage of the revived unit's HP it comes back with, so
  // it moved out of this bucket. DRAW_CARD stays: there is still no in-match
  // hand/deck mechanic for it to draw from (see cn_effect_apply_action's own
  // comment), and 0074 dropped it from the OFFERED vocabulary below rather
  // than building one. SUMMON_OBJECT has no numeric parameter of its own --
  // it is CREATE_STRUCTURE under another name (see STRUCTURE_ACTIONS below)
  // and takes a structure_slug pill instead of a value box.
  'DRAW_CARD', 'SUMMON_OBJECT', 'CREATE_STRUCTURE',
  // 0058: forcing a guaranteed parry has no numeric parameter -- same
  // documented-no-op bucket as its neighbours above.
  'TRIGGER_PARRY',
  // 0093: a structure removing itself from the field has no numeric
  // parameter either -- same pure-verb bucket as TRIGGER_PARRY just above.
  // See StructureEffect['action'] and cn_effect_apply_action's own
  // DESTROY_SELF branch.
  'DESTROY_SELF',
])
const STATUS_ACTIONS = new Set(['APPLY_STATUS', 'REMOVE_STATUS'])
const STAT_ACTIONS = new Set(['MODIFY_STAT', 'COPY_STAT_FROM_TARGET'])
// 0074: CREATE_STRUCTURE/SUMMON_OBJECT (the same action under two names --
// see cn_effect_apply_action) place a row from the `structures` catalog
// table, so both need the structure_slug pill rather than a plain value box.
const STRUCTURE_ACTIONS = new Set(['CREATE_STRUCTURE', 'SUMMON_OBJECT'])
/** Duration is authoring metadata for "how long the applied thing lasts" --
 *  offered only where that question makes sense (a status or a stat
 *  modifier), not on an instant DEAL_DAMAGE/HEAL. See 0056's header on
 *  which of these the engine actually enforces today. */
const DURATION_ACTIONS = new Set(['APPLY_STATUS', 'MODIFY_STAT'])

/** One word or pill in a sentence row. Plain text for connectors ("When",
 *  "If", "Then", "And"), a styled <select> -- a click-to-open dropdown,
 *  exactly the "inline pill-shaped UI block" the spec asks for -- for
 *  anything the admin can swap. */
export function Word({ children }: { children: ReactNode }) {
  return <span className="sb-word">{children}</span>
}

export function Pill({ value, options, onChange, labelFor, title, disabled }: {
  value: string
  options: readonly string[]
  onChange: (v: string) => void
  labelFor?: (v: string) => string
  title?: string
  disabled?: boolean
}) {
  return (
    <select
      className="sb-pill" value={value} title={title} disabled={disabled}
      onChange={(e) => onChange(e.target.value)}
    >
      {options.map((o) => <option key={o} value={o}>{labelFor ? labelFor(o) : o}</option>)}
    </select>
  )
}

export function NumBox({ value, onChange, min, max, placeholder, width }: {
  value: number | string
  onChange: (v: string) => void
  min?: number
  max?: number
  placeholder?: string
  width?: number
}) {
  return (
    <input
      type="number" className="sb-value" value={value} min={min} max={max}
      placeholder={placeholder} style={width ? { width } : undefined}
      onChange={(e) => onChange(e.target.value)}
    />
  )
}

export interface SentenceVocab {
  /** Every trigger offered when this sentence is NOT locked to one -- see
   *  triggerLocked below for the Active-ability case. */
  triggers: readonly string[]
  triggerLabel?: (t: string) => string
  targets: readonly string[]
  /** 0059: human-readable pill text for a target, same idea as
   *  triggerLabel. */
  targetLabel?: (t: string) => string
  /** Empty for a vocabulary with no Range category at all (structures --
   *  see this file's header on why they have none). */
  ranges: readonly string[]
  /** 0059: human-readable pill text for a range option. */
  rangeLabel?: (r: string) => string
  actions: readonly string[]
  actionNoops?: Set<string>
  /** 0058: human-readable pill text for an action, same idea as
   *  triggerLabel above -- falls back to the raw constant when unset (most
   *  actions still read as their own name; only the ones a developer has
   *  actually asked to read as English get an entry). */
  actionLabel?: (a: string) => string
  statuses: readonly string[]
  /** 0059: human-readable pill text for a status option. */
  statusLabel?: (s: string) => string
  statNames: readonly string[]
  runtimeOnlyStats?: Set<string>
  /** 0059: human-readable pill text for a stat_name option. */
  statNameLabel?: (s: string) => string
  /** 0074: every `structures.slug` CREATE_STRUCTURE/SUMMON_OBJECT can place.
   *  Left empty (or unset) for a vocabulary with no structures to offer --
   *  the structure_slug pill then simply does not render, same idea as
   *  `ranges` being empty for structures' own vocab. */
  structures?: readonly string[]
  /** 0074: human-readable pill text for a structure_slug option, same idea
   *  as statNameLabel. */
  structureLabel?: (s: string) => string
  conditionFields: readonly string[]
  /** 0059: human-readable pill text for a condition field
   *  ("self.hp_pct" -> "this card's HP %"). */
  conditionFieldLabel?: (f: string) => string
  conditionOps: readonly string[]
  /** 0075: human-readable pill text for a comparison op ("!=" -> "is not"),
   *  same idea as conditionFieldLabel -- falls back to the raw operator
   *  when unset. The developer's own spec example ("[ is ] [ is not ]")
   *  is one generic phrase per operator, not a per-field grammar, so one
   *  small map does it for every condition field at once. */
  conditionOpLabel?: (op: string) => string
  durations: readonly string[]
  /** 0059: human-readable pill text for a duration option. */
  durationLabel?: (d: string) => string
}

/**
 * One ALL/ANY block, since 0075 -- "IF [ALL ▼] of the following are true:"
 * plus its own children (leaves or nested groups) and its own "+ Condition"
 * / "+ Group" controls. Recursive: a child that is itself a group renders
 * as another ConditionGroupBlock, indented under this one, which is what
 * makes nesting free rather than a special second component.
 *
 * Deliberately its own labelled block rather than woven into the existing
 * "if X and Y" row above -- that inline chain stays exactly as it always
 * read (a flat AND, unchanged for every sentence that never uses a group),
 * and a group reads as a separate clause of the sentence instead of an
 * inline "(Y or Z)" that would need parentheses to be unambiguous. Jared's
 * own spec: no inline AND/OR, ALL/ANY blocks instead.
 */
function ConditionGroupBlock({ group, vocab, onUpdate, onRemove }: {
  group: ConditionGroupRow
  vocab: SentenceVocab
  onUpdate: (patch: Partial<ConditionRow> & Partial<ConditionGroupRow>) => void
  onRemove: () => void
}) {
  const children = group.children ?? []
  const updateChild = (ci: number, patch: Partial<ConditionRow> & Partial<ConditionGroupRow>) => {
    onUpdate({ children: children.map((c, i) => (i === ci ? ({ ...c, ...patch } as ConditionNode) : c)) })
  }
  const removeChild = (ci: number) => {
    onUpdate({ children: children.filter((_, i) => i !== ci) })
  }
  const addChildCondition = () => {
    onUpdate({ children: [...children, { field: vocab.conditionFields[0], op: '=', value: '' }] })
  }
  const addChildGroup = () => {
    onUpdate({ children: [...children, { kind: 'group', mode: 'ALL', children: [] }] })
  }

  return (
    <div className="sb-group">
      <div className="sb-row sb-inline">
        <button
          type="button" className="sb-word sb-word-toggle"
          title="Click to negate this whole group"
          onClick={() => onUpdate({ negate: !group.negate })}
        >
          {group.negate ? 'IF NOT' : 'IF'}
        </button>
        <Pill
          value={group.mode} options={['ALL', 'ANY']}
          onChange={(v) => onUpdate({ mode: v as 'ALL' | 'ANY' })}
          title="ALL requires every condition below; ANY requires at least one"
        />
        <Word>of the following are true:</Word>
        <button type="button" className="sb-x" aria-label="Remove this group" onClick={onRemove}>×</button>
      </div>
      <div className="sb-group-children">
        {children.map((c, ci) => (
          isConditionGroup(c) ? (
            <ConditionGroupBlock
              key={ci} group={c} vocab={vocab}
              onUpdate={(patch) => updateChild(ci, patch)}
              onRemove={() => removeChild(ci)}
            />
          ) : (
            <span className="sb-row sb-inline" key={ci}>
              {/* "and"/"and not" under ALL, "or"/"or not" under ANY -- the
                  connector reads as the real combinator this group applies,
                  not a fixed word borrowed from the top-level AND chain. */}
              <button
                type="button" className="sb-word sb-word-toggle"
                title="Click to negate this condition"
                onClick={() => updateChild(ci, { negate: !c.negate })}
              >
                {ci === 0
                  ? (c.negate ? 'if not' : 'if')
                  : group.mode === 'ANY'
                    ? (c.negate ? 'or not' : 'or')
                    : (c.negate ? 'and not' : 'and')}
              </button>
              <Pill
                value={c.field} options={vocab.conditionFields} title="Condition"
                labelFor={vocab.conditionFieldLabel}
                onChange={(v) => updateChild(ci, { field: v })}
              />
              <Pill
                value={c.op ?? '='} options={vocab.conditionOps} title="Comparison"
                labelFor={vocab.conditionOpLabel}
                onChange={(v) => updateChild(ci, { op: v })}
              />
              <input
                className="sb-value" value={c.value ?? ''} placeholder="value"
                onChange={(e) => updateChild(ci, { value: e.target.value })}
              />
              <button type="button" className="sb-x" aria-label="Remove condition" onClick={() => removeChild(ci)}>×</button>
            </span>
          )
        ))}
        <div className="sb-row">
          <button type="button" className="btn tiny ghost" onClick={addChildCondition}>+ Condition</button>
          <button type="button" className="btn tiny ghost" onClick={addChildGroup}>+ Group</button>
        </div>
      </div>
    </div>
  )
}

export function SentenceBuilder<T extends SentenceRow>({
  vocab, groups, sentenceNoun = 'sentence',
  triggerLocked, triggerLockedLabel,
  onChangeRow, onRemoveRow, onAddClause,
  onSetTrigger, onSetConditions,
  onAddSentence, onRemoveSentence,
  renderSentenceExtra,
}: {
  vocab: SentenceVocab
  groups: SentenceGroup<T>[]
  sentenceNoun?: string
  /** True when this group's trigger is fixed (an Active card ability is
   *  always "When activated") and should render as plain text, not a
   *  dropdown offering a single choice. */
  triggerLocked?: (groupId: string) => boolean
  triggerLockedLabel?: string
  onChangeRow: (rowId: string, patch: Partial<SentenceRow>) => void
  onRemoveRow: (rowId: string) => void
  onAddClause: (groupId: string) => void
  onSetTrigger: (groupId: string, trigger: string) => void
  onSetConditions: (groupId: string, conditions: ConditionNode[]) => void
  onAddSentence: () => void
  onRemoveSentence: (groupId: string) => void
  /** A slot above the trigger row for whatever the caller needs attached to
   *  the whole sentence -- AdminCards.tsx puts the Active/Passive toggle
   *  and Max Uses/Cooldown fields here; AdminStructures.tsx leaves it out. */
  renderSentenceExtra?: (groupId: string, firstRow: T) => ReactNode
}) {
  // Deleting a whole sentence (every block in it, not just one) used to be
  // one click with no way back. Armed by group id rather than a plain
  // boolean, so confirming one sentence's delete never lands on a different
  // one if the list has reflowed.
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null)

  return (
    <div className="sb-root">
      {groups.length === 0 && (
        <p className="muted">Nothing yet. Add a {sentenceNoun} to give it something to do.</p>
      )}
      {groups.map(({ groupId, rows }) => {
        const first = rows[0]
        const conditions = first.conditions ?? []
        const locked = triggerLocked?.(groupId) ?? false

        const updateCondition = (ci: number, patch: Partial<ConditionRow> & Partial<ConditionGroupRow>) => {
          onSetConditions(groupId, conditions.map((c, i) => (i === ci ? ({ ...c, ...patch } as ConditionNode) : c)))
        }
        const addCondition = () => {
          onSetConditions(groupId, [...conditions, { field: vocab.conditionFields[0], op: '=', value: '' }])
        }
        // 0075: "+ If (group)" -- appends a labelled ALL/ANY block, AND'd
        // against everything else at this level exactly the way a plain
        // leaf always was (the top level was always an implicit AND; this
        // just lets one of its elements be a block instead of a leaf). See
        // ConditionGroupBlock's own header for why it renders as its own
        // clause below rather than inline in the "if X and Y" chain above.
        const addConditionGroup = () => {
          onSetConditions(groupId, [...conditions, { kind: 'group', mode: 'ALL', children: [] }])
        }
        const removeCondition = (ci: number) => {
          onSetConditions(groupId, conditions.filter((_, i) => i !== ci))
        }

        return (
          <div key={groupId} className="sb-sentence">
            {renderSentenceExtra?.(groupId, first)}

            <div className="sb-row">
              <Word>When</Word>
              {locked ? (
                <span className="sb-pill sb-pill-locked">{triggerLockedLabel ?? first.trigger}</span>
              ) : (
                <Pill
                  value={first.trigger} options={vocab.triggers} labelFor={vocab.triggerLabel}
                  onChange={(v) => onSetTrigger(groupId, v)} title="Trigger"
                />
              )}
              {conditions.map((c, ci) => {
                if (isConditionGroup(c)) return null
                // "if"/"if not" for the first LEAF encountered (a group
                // elsewhere in the array does not count -- it renders as
                // its own block below, not a word in this chain), "and"/
                // "and not" for every leaf after it.
                const isFirstLeaf = conditions.slice(0, ci).every(isConditionGroup)
                return (
                  <span className="sb-row sb-inline" key={ci}>
                    {/* 0074: a clickable connector, not plain text -- toggles
                        this one condition's negate flag. Every condition is
                        still AND'd together (see ConditionRow.negate's own
                        comment); this only flips the individual term, so
                        "and not" reads exactly as naturally as "and" does. */}
                    <button
                      type="button" className="sb-word sb-word-toggle"
                      title="Click to negate this condition"
                      onClick={() => updateCondition(ci, { negate: !c.negate })}
                    >
                      {isFirstLeaf ? (c.negate ? 'if not' : 'if') : (c.negate ? 'and not' : 'and')}
                    </button>
                    <Pill
                      value={c.field} options={vocab.conditionFields} title="Condition"
                      labelFor={vocab.conditionFieldLabel}
                      onChange={(v) => updateCondition(ci, { field: v })}
                    />
                    <Pill
                      value={c.op ?? '='} options={vocab.conditionOps} title="Comparison"
                      labelFor={vocab.conditionOpLabel}
                      onChange={(v) => updateCondition(ci, { op: v })}
                    />
                    <input
                      className="sb-value" value={c.value ?? ''} placeholder="value"
                      onChange={(e) => updateCondition(ci, { value: e.target.value })}
                    />
                    <button type="button" className="sb-x" aria-label="Remove condition" onClick={() => removeCondition(ci)}>×</button>
                  </span>
                )
              })}
              <button type="button" className="btn tiny ghost" onClick={addCondition}>+ If</button>
              <button type="button" className="btn tiny ghost" onClick={addConditionGroup}>+ If (group)</button>
            </div>

            {/* 0075: any top-level ALL/ANY blocks, each its own clause,
                AND'd against the "if X and Y" chain above and against each
                other -- see addConditionGroup's own comment. */}
            {conditions.map((c, ci) => (
              isConditionGroup(c) ? (
                <ConditionGroupBlock
                  key={ci} group={c} vocab={vocab}
                  onUpdate={(patch) => updateCondition(ci, patch)}
                  onRemove={() => removeCondition(ci)}
                />
              ) : null
            ))}

            {rows.map((row, ri) => {
              // APPLY_STATUS never shows a value box, for any status,
              // Burning/Poison/Stun alike -- Jared: "all status now don't
              // have a number before them ... except stunned, so please
              // update it." STUN was the one held back initially because
              // cn_effect_apply_action reads `value` for it as a turn count
              // (`cn_afflict(u, 'stun', to_jsonb(greatest(1, v_value)))`) --
              // but v_value is itself `coalesce((p_effect->>'value')::int, 0)`
              // (0074's own executor), so an unset value is already 0 there
              // and `greatest(1, 0)` is 1: a row with no value box at all
              // afflicts a clean 1-turn stun, the same safe floor the engine
              // was already applying whenever a card left this blank. Checked
              // live (dnhvfajvfhmqpbwfvyfq): zero rows in card_effects or
              // structure_effects have ever set APPLY_STATUS/STUN with a
              // value, soft-coded or not, so there is nothing this silently
              // changes for an existing card -- burn/poison were already
              // booleans (see this file's own note below on cn_afflict's
              // overwrite semantics), and stun now reads the same way.
              const needsValue = !NO_VALUE_ACTIONS.has(row.action)
                && row.action !== 'APPLY_STATUS'
              const needsStatus = STATUS_ACTIONS.has(row.action)
              const needsStat = STAT_ACTIONS.has(row.action)
              const needsStructure = STRUCTURE_ACTIONS.has(row.action)
              const needsDuration = DURATION_ACTIONS.has(row.action)
              return (
                <div className="sb-row" key={row.id}>
                  <Word>{ri === 0 ? 'then' : 'and'}</Word>
                  <Pill
                    value={row.target_selector} options={vocab.targets} title="Target"
                    labelFor={vocab.targetLabel}
                    onChange={(v) => onChangeRow(row.id, { target_selector: v })}
                  />
                  {vocab.ranges.length > 0 && (
                    <Pill
                      value={row.range_kind ?? vocab.ranges[0]} options={vocab.ranges} title="Range"
                      labelFor={vocab.rangeLabel}
                      onChange={(v) => onChangeRow(row.id, {
                        range_kind: v,
                        range_min: v === 'FIXED_RANGE' ? (row.range_min ?? 1) : null,
                        range_max: v === 'FIXED_RANGE' ? (row.range_max ?? 4) : null,
                      })}
                    />
                  )}
                  {vocab.ranges.length > 0 && row.range_kind === 'FIXED_RANGE' && (
                    <>
                      <NumBox value={row.range_min ?? 1} min={1} max={4} width={54}
                        onChange={(v) => onChangeRow(row.id, { range_min: v === '' ? null : Number(v) })} />
                      <Word>to</Word>
                      <NumBox value={row.range_max ?? 4} min={1} max={4} width={54}
                        onChange={(v) => onChangeRow(row.id, { range_max: v === '' ? null : Number(v) })} />
                    </>
                  )}
                  <Pill
                    value={row.action} options={vocab.actions} title="Action"
                    labelFor={(a) => (vocab.actionLabel?.(a) ?? a) + (vocab.actionNoops?.has(a) ? ' (not built yet)' : '')}
                    onChange={(v) => onChangeRow(row.id, { action: v })}
                  />
                  {needsValue && (
                    <NumBox value={row.value ?? ''} placeholder="value" width={64}
                      onChange={(v) => onChangeRow(row.id, { value: v === '' ? null : Number(v) })} />
                  )}
                  {needsStatus && (
                    <Pill
                      value={row.status ?? vocab.statuses[0]} options={vocab.statuses} title="Status"
                      labelFor={vocab.statusLabel}
                      onChange={(v) => onChangeRow(row.id, { status: v })}
                    />
                  )}
                  {needsStat && (
                    <Pill
                      value={row.stat_name ?? vocab.statNames[0]} options={vocab.statNames} title="Stat"
                      labelFor={(s) => (vocab.statNameLabel?.(s) ?? s) + (vocab.runtimeOnlyStats?.has(s) ? ' (runtime only)' : '')}
                      onChange={(v) => onChangeRow(row.id, { stat_name: v })}
                    />
                  )}
                  {needsStructure && vocab.structures && vocab.structures.length > 0 && (
                    <Pill
                      value={row.structure_slug ?? vocab.structures[0]} options={vocab.structures}
                      title="Structure" labelFor={vocab.structureLabel}
                      onChange={(v) => onChangeRow(row.id, { structure_slug: v })}
                    />
                  )}
                  {needsStructure && (!vocab.structures || vocab.structures.length === 0) && (
                    <span className="muted tiny">(no structures yet)</span>
                  )}
                  {needsDuration && (
                    <>
                      <Pill
                        value={row.duration_kind ?? 'THIS_TURN'} options={vocab.durations} title="Duration"
                        labelFor={vocab.durationLabel}
                        onChange={(v) => onChangeRow(row.id, {
                          duration_kind: v, duration_turns: v === 'FOR_TURNS' ? (row.duration_turns ?? 2) : null,
                        })}
                      />
                      {row.duration_kind === 'FOR_TURNS' && (
                        <NumBox value={row.duration_turns ?? 2} min={2} max={5} width={48}
                          onChange={(v) => onChangeRow(row.id, { duration_turns: v === '' ? null : Number(v) })} />
                      )}
                    </>
                  )}
                  <button type="button" className="sb-x" aria-label="Remove this block" onClick={() => onRemoveRow(row.id)}>×</button>
                </div>
              )
            })}

            <div className="sb-row sb-sentence-acts">
              <button type="button" className="btn tiny ghost" onClick={() => onAddClause(groupId)}>+ Add Block</button>
              {confirmRemove === groupId ? (
                <>
                  <span className="admin-bantext">Really delete this {sentenceNoun}? This cannot be undone.</span>
                  <button
                    type="button" className="btn tiny danger"
                    onClick={() => { onRemoveSentence(groupId); setConfirmRemove(null) }}
                  >
                    Yes, delete
                  </button>
                  <button type="button" className="btn tiny ghost" onClick={() => setConfirmRemove(null)}>
                    No
                  </button>
                </>
              ) : (
                <button type="button" className="btn tiny danger ghost" onClick={() => setConfirmRemove(groupId)}>
                  Delete this {sentenceNoun}
                </button>
              )}
            </div>
          </div>
        )
      })}

      <button type="button" className="btn ghost" onClick={onAddSentence}>+ New {sentenceNoun}</button>
    </div>
  )
}
