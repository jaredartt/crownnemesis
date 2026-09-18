import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { adminDeleteCard } from '../lib/api'
import { artUrl, faceUrl } from '../lib/art'
import type { Card, CardEffect, CardAbilityMeta } from '../lib/types'
import { clearCards } from '../lib/useCards'
import {
  SentenceBuilder, groupSentences, type SentenceVocab, type SentenceRow,
} from './SentenceBuilder'

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
// `royal` (and, until 0059, `flies`) is now a PASSIVE/MODIFY_STAT row on the
// "Abilities & Passives" tab below (parry_all, parries, burns, heals, cures,
// sneaks, tramples, blooms) -- see cn_compile_card_effects. `royal` stays
// here because it is a structural fact cn_check_card enforces (one crown
// per kingdom), not a compiler-owned column. LEAVING THE OTHER EIGHT HERE
// TOO WOULD BE A REAL BUG, not merely a redundant control: the compiler
// RESETS every column it owns to false and re-derives it from card_effects
// rows every time ANY row for this card changes (see that function's own
// comment), so a raw checkbox edit made here would be silently reverted the
// next time the Abilities tab saved anything for the same card -- two
// sources of truth for one column, and the newer write always loses.
//
// 0059: `flies` removed from this list at Jared's request. It was ALREADY
// dead as an editable control before this -- `cn_check_card`'s BEFORE
// trigger sets `new.flies := (new.role = 'flying')` unconditionally on
// every write, so this checkbox's own value was silently overwritten the
// instant Save ran. The `flies` column, that trigger, and the `role`
// dropdown's own "Flying" option are all untouched: this removes a control
// that never did anything, not the mechanic. See
// 0059_evasion_and_labels.sql's header.
const FLAGS = [
  ['royal', 'Royal'],
] as const

// The full soft-coded vocabulary, since 0049 -- see
// supabase/migrations/0049_card_effects_engine.sql's header and the
// card_effects table's own column comments for what each one means and, for
// everything past the developer's original list, why it was added.
const TRIGGERS: CardEffect['trigger'][] = [
  'ON_PLAY', 'ON_ABILITY', 'ON_ATTACK', 'ON_DEATH', 'START_OF_TURN',
  'END_OF_TURN', 'ON_PARRY', 'PASSIVE',
  'ON_COUNTER', 'ON_KILL', 'ON_HEALED', 'ON_DAMAGED', 'ON_STATUS_APPLIED',
  // 0058: the mirror of ON_PARRY -- see card_effects.trigger's own column
  // comment (0058_parry_vocabulary.sql) for what each side of the swing
  // means.
  'IS_PARRIED',
]
// 0058 labelled just the three Jared named by their English text; 0059
// widens this to every trigger, so the pill never falls back to a raw
// constant -- a builder that translates "parries" but leaves "ON_ATTACK"
// sitting there in caps is the exact half-translated experience Jared
// asked to have fixed.
const TRIGGER_LABELS: Record<string, string> = {
  ON_PLAY: 'is played',
  ON_ABILITY: 'activates its ability',
  ON_ATTACK: 'attacks',
  ON_DEATH: 'dies',
  START_OF_TURN: 'the turn starts',
  END_OF_TURN: 'the turn ends',
  ON_PARRY: 'parries',
  PASSIVE: 'is on the field',
  ON_COUNTER: 'counter-attacks',
  ON_KILL: 'defeats an enemy',
  ON_HEALED: 'is healed',
  ON_DAMAGED: 'takes damage',
  ON_STATUS_APPLIED: 'gains a status effect',
  IS_PARRIED: 'is parried',
}
const triggerLabel = (t: string) => TRIGGER_LABELS[t] ?? t
// 0059: every target, same reasoning.
const TARGET_LABELS: Record<string, string> = {
  SELF: 'this card',
  NEARBY_ALLIES: 'nearby allies',
  ALL_ALLIES: 'all allies',
  ENEMY_IN_RANGE: 'an enemy in range',
  LOWEST_HP_ENEMY: 'the lowest-HP enemy',
  BOARD_CELL: 'a chosen tile',
  ALL_ENEMIES: 'all enemies',
  NEAREST_ENEMY: 'the nearest enemy',
  HIGHEST_HP_ENEMY: 'the highest-HP enemy',
  LOWEST_HP_ALLY: 'the lowest-HP ally',
  HIGHEST_HP_ALLY: 'the highest-HP ally',
  RANDOM_ENEMY_IN_RANGE: 'a random enemy in range',
  RANDOM_ALLY: 'a random ally',
  ALLIES_IN_LINE: 'allies in a line',
  ENEMIES_IN_LINE: 'enemies in a line',
  THE_ATTACKER: 'the attacker',
  THE_TARGET: 'the target',
  ADJACENT_UNITS: 'adjacent units',
  // 0074: the graveyard selector REVIVE reads -- see cn_resolve_targets'
  // own '#'-prefixed-id branch and cn_bury/state.graveyard for what feeds
  // it. Offered for REVIVE only in practice (nothing else asks for a dead
  // unit), but not restricted here -- the server is what enforces meaning,
  // this screen just offers the vocabulary.
  LAST_DEAD_ALLY: 'the last ally who died',
}
const targetLabel = (t: string) => TARGET_LABELS[t] ?? t
const TARGETS: CardEffect['target_selector'][] = [
  'SELF', 'NEARBY_ALLIES', 'ALL_ALLIES', 'ENEMY_IN_RANGE', 'LOWEST_HP_ENEMY',
  'BOARD_CELL', 'ALL_ENEMIES', 'NEAREST_ENEMY', 'HIGHEST_HP_ENEMY',
  'LOWEST_HP_ALLY', 'HIGHEST_HP_ALLY', 'RANDOM_ENEMY_IN_RANGE', 'RANDOM_ALLY',
  'ALLIES_IN_LINE', 'ENEMIES_IN_LINE', 'THE_ATTACKER', 'THE_TARGET',
  'ADJACENT_UNITS', 'LAST_DEAD_ALLY',
]
// 0074: every one of these is now really built -- see
// 0074_not_built_yet_actions.sql's header for what each of REVIVE/
// REFLECT_DAMAGE_PCT/SUMMON_OBJECT/TRIGGER_PARRY actually does now. Two
// names are deliberately left OFF this offered list even though the schema
// (and CardEffect['action']) still accepts them, for reasons that are about
// this game's own rules rather than anything left unbuilt:
//   - DRAW_CARD: there is no in-match hand/deck to draw from -- nothing this
//     screen could offer would do anything, so it stays out of the
//     vocabulary rather than sitting here as a lie. cn_effect_apply_action
//     still no-ops it for any pre-existing row.
//   - COUNTER_ATTACK_PCT: for a CARD specifically this is redundant with how
//     combat already works -- a unit in range already counters automatically,
//     so a scripted "counter-attack %" on a card would just be a second,
//     confusing counter. It IS built and offered for STRUCTURES (see
//     AdminStructures.tsx), which have no automatic retaliation of their own.
// CREATE_STRUCTURE is new to this list: it always existed as a real action
// (SUMMON_OBJECT is simply its alias -- see cn_effect_apply_action), it just
// was not offered here before 0074.
const ACTIONS: CardEffect['action'][] = [
  'DEAL_DAMAGE', 'HEAL', 'APPLY_STATUS', 'MODIFY_STAT', 'PUSH_BACK',
  'REMOVE_STATUS', 'GRANT_EXTRA_ACTIVATION', 'CREATE_STRUCTURE', 'SUMMON_OBJECT',
  'TELEPORT_SELF', 'SWAP_POSITIONS', 'REVIVE', 'COPY_STAT_FROM_TARGET',
  'REFLECT_DAMAGE_PCT', 'TRIGGER_PARRY',
]
// Empty as of 0074 -- every action offered above is real now. Kept (rather
// than removed) because SentenceBuilder's actionNoops plumbing is shared
// with AdminStructures.tsx, whose own vocab still uses it, and because the
// next genuinely-unbuilt action (if one is ever added to the schema ahead of
// its engine support) has somewhere honest to be flagged.
const ACTION_NOOPS = new Set<CardEffect['action']>([])
// 0059: every action, same widening as TRIGGER_LABELS above.
// REFLECT_DAMAGE_PCT's/REVIVE's value box (rendered right after this pill,
// since neither is in SentenceBuilder's NO_VALUE_ACTIONS) stands in for the
// developer's own "[1-100%]" bracket. COUNTER_ATTACK_PCT works the same way
// but is only offered on the Structures screen now -- see ACTIONS above.
const ACTION_LABELS: Record<string, string> = {
  DEAL_DAMAGE: 'deals damage to',
  HEAL: 'heals',
  APPLY_STATUS: 'applies status',
  MODIFY_STAT: 'modifies stat of',
  PUSH_BACK: 'pushes back',
  DRAW_CARD: 'draws a card for',
  REMOVE_STATUS: 'removes status from',
  GRANT_EXTRA_ACTIVATION: 'grants an extra activation to',
  // 0074: "near" removed at Jared's request -- the Range pill already sits
  // right before this one in the sentence and says exactly how near, so
  // the word here was only repeating it. Also no trailing "at": the
  // structure_slug pill that follows this one is the structure's NAME, not
  // a place -- "places a structure at Trap" read like "Trap" was a
  // location, per Jared's own catch on Mako's ability. "places Trap" (the
  // pill sits right after the verb) says what is actually happening.
  SUMMON_OBJECT: 'summons',
  CREATE_STRUCTURE: 'places',
  TELEPORT_SELF: 'teleports',
  SWAP_POSITIONS: 'swaps positions with',
  // 0074: hints at the value box that now follows this pill -- REVIVE is no
  // longer a no-op, and the value is what % HP the revived unit comes back
  // with (see card_effects_revive_value_check).
  REVIVE: 'revives, at % HP',
  COPY_STAT_FROM_TARGET: 'copies a stat from',
  REFLECT_DAMAGE_PCT: 'reflects % damage to',
  TRIGGER_PARRY: 'triggers Parry against',
  COUNTER_ATTACK_PCT: 'counter-attacks % damage to',
}
const actionLabel = (a: string) => ACTION_LABELS[a] ?? a
// 0059: every status option.
const STATUS_LABELS: Record<string, string> = {
  NONE: 'no status', BURNING: 'Burning', STUN: 'Stunned', POISON: 'Poisoned',
  ANY: 'any status', ALL: 'every status',
}
const statusLabel = (st: string) => STATUS_LABELS[st] ?? st
const STATUSES: NonNullable<CardEffect['status']>[] = [
  'NONE', 'BURNING', 'STUN', 'POISON', 'ANY', 'ALL',
]
// 0059: SLIPPERY and FLIES removed from this OFFERED list at Jared's
// request -- "I don't think it makes sense to include a unit's ability in
// there." Neither is removed from the schema (`card_effects_stat_name_check`
// still accepts both, and Himanta's existing SLIPPERY row keeps compiling
// and keeps working) -- this is an authoring-vocabulary cut, not a data or
// engine change. See 0059_evasion_and_labels.sql's header for the rest of
// that reasoning, and EVASION_PCT below for what Jared asked to replace it
// with: a real, new percentage stat, not a relabel of the old one.
const STAT_NAMES = [
  'TWICE_PCT', 'LIFESTEAL_PCT', 'PARRY_ALL', 'REGEN_PCT',
  'STUNS_ON_HIT', 'POISONS_ADJACENT', 'VS_POISONED_BONUS', 'CURES_BURN',
  'BLOOMS', 'SNEAKS', 'TRAMPLES', 'PARRIES', 'BURNS', 'HEALS',
  'SWAMPS',
  // 0059: a real dodge-chance roll in cn_attack -- see that migration's
  // header for exactly what it does and does not affect (no damage, no
  // counter, no chain, when it lands).
  'EVASION_PCT',
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
// 0059: every stat_name option. SWAMPS/SNEAKS/BLOOMS/CURES_BURN read from
// what each field's own column comment in lib/types.ts says it actually
// does, not guessed at from the name alone.
const STAT_NAME_LABELS: Record<string, string> = {
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
  TRAMPLES: 'tramples trees',
  PARRIES: 'counters before being hit',
  BURNS: 'burns on hit',
  HEALS: 'heals instead of attacking',
  SWAMPS: "silences nearby units' abilities",
  EVASION_PCT: 'evasion % (dodges the attack entirely)',
  // 0060: bonus = outgoing (cn_aura_bonus: your team's dmg TO that class);
  // resist = incoming (cn_aura_resist: your team's dmg FROM that class).
  AURA_RESIST_KNIGHT: 'team takes reduced % damage FROM Knights',
  AURA_RESIST_ROGUE: 'team takes reduced % damage FROM Rogues',
  AURA_RESIST_MAGE: 'team takes reduced % damage FROM Mages',
  AURA_RESIST_FLYING: 'team takes reduced % damage FROM Flying',
  AURA_BONUS_KNIGHT: 'team deals bonus % damage TO Knights',
  AURA_BONUS_ROGUE: 'team deals bonus % damage TO Rogues',
  AURA_BONUS_MAGE: 'team deals bonus % damage TO Mages',
  AURA_BONUS_FLYING: 'team deals bonus % damage TO Flying',
  AURA_RESIST_EFFECTS: 'team takes reduced % damage from burn/poison ticks',
  HP: 'HP', MOV: 'Move', RMIN: 'min range', RMAX: 'max range',
  CRMIN: 'min counter range', CRMAX: 'max counter range', POWER: 'power',
  PARRY_PCT: 'parry %', CRIT_PCT: 'crit %',
}
const statNameLabel = (st: string) => STAT_NAME_LABELS[st] ?? st
// Every field cn_effect_condition_met (0049) knows how to read, so a
// condition built here is guaranteed to mean something on the server rather
// than silently evaluating to "true" (that function's own fallback for a
// field it does not recognise).
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
const CONDITION_OPS = ['=', '!=', '<', '<=', '>', '>=', 'in'] as const
// 0059: every condition field.
const CONDITION_FIELD_LABELS: Record<string, string> = {
  'self.hp_pct': "this card's HP %",
  'target.hp_pct': "target's HP %",
  'self.hp': "this card's HP",
  'target.hp': "target's HP",
  'self.role': "this card's class",
  'target.role': "target's class",
  'self.has_status': 'this card has status',
  'target.has_status': 'target has status',
  roll_pct: 'random roll %',
  turn_number: 'turn number',
  is_royal_target: 'target is royal',
  units_adjacent_count: 'units adjacent',
}
const conditionFieldLabel = (f: string) => CONDITION_FIELD_LABELS[f] ?? f

// 0056: the Ability Type toggle. Active is not a fifteenth trigger next to
// the other thirteen -- it is a fixed slot every card has at most one of
// (see card_ability_meta's own header), so its trigger is locked rather
// than offered in a dropdown, and every OTHER trigger is what a Passive
// sentence still picks from exactly as before.
const ACTIVE_TRIGGER: CardEffect['trigger'] = 'ON_ABILITY'
const PASSIVE_TRIGGERS: CardEffect['trigger'][] = TRIGGERS.filter((t) => t !== ACTIVE_TRIGGER)
// 0056: the Duration and Range Mad-Libs categories -- see card_effects'
// duration_kind/range_kind column comments (0056_ability_sentences.sql) for
// exactly what the engine does and does not enforce for each value yet.
const DURATIONS: NonNullable<CardEffect['duration_kind']>[] = ['THIS_TURN', 'FOR_TURNS', 'UNTIL_REMOVED']
const RANGES: NonNullable<CardEffect['range_kind']>[] = ['CARD_RANGE', 'FIXED_RANGE', 'ANYWHERE', 'PLAYER_CHOOSES']
// 0059: every duration/range option.
const DURATION_LABELS: Record<string, string> = {
  THIS_TURN: 'this turn',
  FOR_TURNS: 'for a number of turns',
  UNTIL_REMOVED: 'until removed',
}
const durationLabel = (d: string) => DURATION_LABELS[d] ?? d
const RANGE_LABELS: Record<string, string> = {
  CARD_RANGE: 'in card range',
  FIXED_RANGE: 'in a fixed range',
  ANYWHERE: 'anywhere on the board',
  PLAYER_CHOOSES: 'wherever the player chooses',
}
const rangeLabel = (r: string) => RANGE_LABELS[r] ?? r

// 0074: CREATE_STRUCTURE/SUMMON_OBJECT's structure_slug pill needs the
// catalog itself, which -- unlike everything else in CARD_VOCAB below --
// is data, not a fixed constant, so it cannot be built at module scope. See
// AdminCards()'s own `structures` state and cardVocab() below for how it is
// spliced in.
function structureLabel(structures: { slug: string; name: string }[]) {
  const byslug = new Map(structures.map((s) => [s.slug, s.name]))
  return (slug: string) => byslug.get(slug) ?? slug
}
function cardVocab(structures: { slug: string; name: string }[]): SentenceVocab {
  return {
    triggers: PASSIVE_TRIGGERS,
    triggerLabel,
    targets: TARGETS,
    targetLabel,
    ranges: RANGES,
    rangeLabel,
    actions: ACTIONS,
    actionNoops: ACTION_NOOPS,
    actionLabel,
    statuses: STATUSES,
    statusLabel,
    statNames: STAT_NAMES,
    statNameLabel,
    runtimeOnlyStats: RUNTIME_ONLY_STATS,
    structures: structures.map((s) => s.slug),
    structureLabel: structureLabel(structures),
    conditionFields: CONDITION_FIELDS,
    conditionFieldLabel,
    conditionOps: CONDITION_OPS,
    durations: DURATIONS,
    durationLabel,
  }
}
// Infinite, or 1 through 5 -- the developer's spec for Max Uses, spelled
// as strings because a <select> only ever hands back strings; '' reads as
// "Infinite" (max_uses = null) on the way back out.
const MAX_USES_OPTIONS = ['', '1', '2', '3', '4', '5'] as const

/** A brand-new row this screen is building, before it has a database id.
 *  Given one here rather than left undefined so React has a stable key and
 *  saveEffects() can tell "already in the table" from "not yet" without a
 *  second array to track it in. */
let nextTempId = 1
function newGroupId(): string {
  return (typeof crypto !== 'undefined' && crypto.randomUUID)
    ? crypto.randomUUID()
    : `g-${nextTempId++}-${Date.now()}`
}
function blankEffect(cardId: string, sort: number, groupId?: string): CardEffect {
  return {
    id: `new-${nextTempId++}`, card_id: cardId, sort, group_id: groupId ?? newGroupId(),
    trigger: 'PASSIVE', target_selector: 'SELF', action: 'MODIFY_STAT',
    value: null, status: null, stat_name: 'SLIPPERY', conditions: [],
    duration_kind: null, duration_turns: null,
    range_kind: null, range_min: null, range_max: null,
    structure_slug: null,
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
  // 0056: the Active sentence's cost, one row per (card, group_id) --
  // loaded and saved alongside `effects` rather than lazily, since the
  // Active/Passive toggle needs to know it the instant the tab opens.
  const [abilityMeta, setAbilityMeta] = useState<CardAbilityMeta[]>([])
  const [effectsBusy, setEffectsBusy] = useState(false)
  const [effectsErr, setEffectsErr] = useState<string | null>(null)
  const [effectsNote, setEffectsNote] = useState<string | null>(null)
  // 0074: the structures catalog, for CREATE_STRUCTURE/SUMMON_OBJECT's
  // structure_slug pill -- loaded once, the same way `rows` is, rather than
  // per-card, since it does not depend on which card is open.
  const [structures, setStructures] = useState<{ slug: string; name: string }[]>([])

  const loadEffects = useCallback(async (cardId: string) => {
    if (cardId === 'new') { setEffects([]); setAbilityMeta([]); return }
    const [effectsRes, metaRes] = await Promise.all([
      supabase.from('card_effects').select('*').eq('card_id', cardId).order('sort'),
      supabase.from('card_ability_meta').select('*').eq('card_id', cardId),
    ])
    if (effectsRes.error) { setEffectsErr(effectsRes.error.message); return }
    setEffects((effectsRes.data ?? []) as CardEffect[])
    setAbilityMeta((metaRes.data ?? []) as CardAbilityMeta[])
  }, [])

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('cards').select('*').order('sort')
    if (error) { setErr(error.message); return }
    setRows((data ?? []) as Row[])
  }, [])
  useEffect(() => { void load() }, [load])

  useEffect(() => {
    void (async () => {
      const { data } = await supabase.from('structures').select('slug, name').order('name')
      setStructures((data ?? []) as { slug: string; name: string }[])
    })()
  }, [])

  function open(r: Row) {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenId(r.id); setDraft({ ...r })
    setFormTab('stats'); setEffectsErr(null); setEffectsNote(null)
    void loadEffects(r.id)
  }
  function blank() {
    setErr(null); setNote(null); setConfirmDelete(null)
    setOpenId('new'); setDraft({ id: 'new', ...BLANK })
    setFormTab('stats'); setEffects([]); setAbilityMeta([]); setEffectsErr(null); setEffectsNote(null)
  }
  const set = (patch: Partial<Row>) => setDraft((d) => (d ? { ...d, ...patch } : d))

  // 0056: every handler below works on a GROUP (one authored sentence) or
  // a single ROW within it, addressed by id -- not by array index, which
  // stopped being stable the moment one card could hold several
  // independently-orderable sentences. groupIdOf falls back to the row's
  // own id for anything saved before 0056 gave every row a real group_id.
  function groupIdOf(e: CardEffect): string {
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
    setEffects((es) => es.map((e) => (e.id === rowId ? { ...e, ...(patch as Partial<CardEffect>) } : e)))
  }
  function onRemoveRow(rowId: string) {
    setEffects((es) => {
      const target = es.find((e) => e.id === rowId)
      if (!target) return es
      const gid = groupIdOf(target)
      // The last block in a sentence is removed by deleting the whole
      // sentence (below) -- a trigger with conditions but no action row is
      // not a shape card_effects can hold, so this declines rather than
      // producing one.
      if (es.filter((e) => groupIdOf(e) === gid).length <= 1) return es
      return es.filter((e) => e.id !== rowId)
    })
  }
  function onSetTrigger(groupId: string, trigger: string) {
    setEffects((es) => es.map((e) => (
      groupIdOf(e) === groupId ? { ...e, trigger: trigger as CardEffect['trigger'] } : e
    )))
  }
  function onSetConditions(groupId: string, conditions: CardEffect['conditions']) {
    setEffects((es) => es.map((e) => (groupIdOf(e) === groupId ? { ...e, conditions } : e)))
  }
  function onRemoveSentence(groupId: string) {
    setEffects((es) => es.filter((e) => groupIdOf(e) !== groupId))
    setAbilityMeta((ms) => ms.filter((m) => m.group_id !== groupId))
  }

  // 0056: the Ability Type toggle. AT MOST ONE ACTIVE SENTENCE PER CARD --
  // see card_ability_meta's own header -- so switching one sentence to
  // Active demotes whichever other one was Active back to Passive here,
  // client-side, rather than letting the save hit the server's partial
  // unique index and surface that as a raw constraint error.
  function onSetAbilityType(groupId: string, isActive: boolean) {
    if (!draft) return
    setEffects((es) => es.map((e) => {
      const gid = groupIdOf(e)
      if (gid === groupId) return { ...e, trigger: isActive ? ACTIVE_TRIGGER : 'PASSIVE' }
      if (isActive && e.trigger === ACTIVE_TRIGGER) return { ...e, trigger: 'PASSIVE' }
      return e
    }))
    setAbilityMeta((ms) => {
      const without = ms.filter((m) => m.group_id !== groupId && !(isActive && m.ability_type === 'active'))
      if (!isActive) return without
      const existing = ms.find((m) => m.group_id === groupId)
      return [...without, existing
        ? { ...existing, ability_type: 'active' as const }
        : { card_id: draft.id, group_id: groupId, ability_type: 'active' as const, max_uses: null, cooldown_turns: 0 }]
    })
  }
  function onSetAbilityMeta(groupId: string, patch: Partial<CardAbilityMeta>) {
    if (!draft) return
    setAbilityMeta((ms) => {
      const existing = ms.find((m) => m.group_id === groupId)
      if (existing) return ms.map((m) => (m.group_id === groupId ? { ...m, ...patch } : m))
      return [...ms, {
        card_id: draft.id, group_id: groupId, ability_type: 'active' as const,
        max_uses: null, cooldown_turns: 0, ...patch,
      }]
    })
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
        card_id: draft.id, sort: i, group_id: e.group_id, trigger: e.trigger,
        target_selector: e.target_selector, action: e.action, value: e.value ?? null,
        status: e.status ?? null, stat_name: e.stat_name ?? null, conditions: e.conditions,
        duration_kind: e.duration_kind ?? null, duration_turns: e.duration_turns ?? null,
        range_kind: e.range_kind ?? null, range_min: e.range_min ?? null, range_max: e.range_max ?? null,
        structure_slug: e.structure_slug ?? null,
      }))
      const { error: insErr } = await supabase.from('card_effects').insert(body)
      if (insErr) { setEffectsBusy(false); setEffectsErr(insErr.message); return }
    }

    // 0056: card_ability_meta is replaced the same way -- delete every row
    // for this card, then insert whichever sentence is still Active (there
    // is at most one: the partial unique index would refuse a second, and
    // onSetAbilityType already keeps the client from building one).
    const { error: metaDelErr } = await supabase.from('card_ability_meta').delete().eq('card_id', draft.id)
    if (metaDelErr) { setEffectsBusy(false); setEffectsErr(metaDelErr.message); return }
    const activeMeta = abilityMeta.find((m) => m.ability_type === 'active'
      && effects.some((e) => (e.group_id || e.id) === m.group_id))
    if (activeMeta) {
      const { error: metaInsErr } = await supabase.from('card_ability_meta').insert({
        card_id: draft.id, group_id: activeMeta.group_id, ability_type: 'active',
        max_uses: activeMeta.max_uses ?? null, cooldown_turns: activeMeta.cooldown_turns ?? 0,
      })
      if (metaInsErr) { setEffectsBusy(false); setEffectsErr(metaInsErr.message); return }
    }

    // 0056: cards.ability_kind is what tells cn_ability an activated
    // ability exists, and what the client reads to draw the Activate
    // Ability button -- see Unit.abilityKind's own comment. An ON_ABILITY
    // sentence existing is now the one source of truth for "does this card
    // have a scripted active ability", the same way the compiler already
    // owns the eight passive checkbox columns on this same table. A card
    // whose ability_kind is one of the six HARDCODED kinds (aoe_adjacent/
    // heal_any/mist/poison_hit/line_burn/summon) is left alone either way --
    // those are not something this tab can author, and saving a passive
    // sentence here must not silently clear one.
    const hasActiveSentence = effects.some((e) => e.trigger === ACTIVE_TRIGGER)
    if (hasActiveSentence && draft.ability_kind !== 'scripted') {
      await supabase.from('cards').update({ ability_kind: 'scripted' }).eq('id', draft.id)
    } else if (!hasActiveSentence && draft.ability_kind === 'scripted') {
      await supabase.from('cards').update({ ability_kind: null }).eq('id', draft.id)
    }

    setEffectsBusy(false)
    setEffectsNote('Saved.')
    await loadEffects(draft.id)
    const { data: freshCard } = await supabase.from('cards').select('ability_kind').eq('id', draft.id).single()
    if (freshCard) {
      setDraft((d) => (d ? { ...d, ability_kind: (freshCard as { ability_kind: string | null }).ability_kind } : d))
    }
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
   * The real delete, since 0046 (and no longer gated on retiring first,
   * since 0055) -- see admin_delete_card() in
   * 0055_delete_active_cards.sql for every check the server makes before it
   * lets the row go: not in anyone's deck or kingdom, not on the board in a
   * match that has not finished. This screen shows whatever sentence comes
   * back rather than a generic "could not delete" -- the same treatment
   * save()'s errors get.
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
              structures={structures}
              abilityMeta={abilityMeta}
              busy={effectsBusy}
              err={effectsErr}
              note={effectsNote}
              onAddSentence={onAddSentence}
              onAddClause={onAddClause}
              onChangeRow={onChangeRow}
              onRemoveRow={onRemoveRow}
              onSetTrigger={onSetTrigger}
              onSetConditions={onSetConditions}
              onRemoveSentence={onRemoveSentence}
              onSetAbilityType={onSetAbilityType}
              onSetAbilityMeta={onSetAbilityMeta}
              onSave={() => void saveEffects()}
            />
          )}

          <div className="actionbar admin-acts">
            {/* Distinct labels, since this sits right below the Abilities tab's
               OWN Save button (which only writes card_effects/card_ability_meta) --
               two identical unlabelled "Save" buttons on screen at once was the
               actual confusion, not just their width. This one is the card row:
               slug/name/role/accent/"in the game" plus, on the Stats tab, the
               numbers/flags/ability text/art/audio above. */}
            <button className="btn primary" disabled={busy}>
              {busy ? 'Saving card…' : 'Save card'}
            </button>
            <button
              type="button" className="btn ghost" disabled={busy}
              onClick={() => { const r = rows.find((x) => x.id === openId); if (r) open(r) }}
            >
              Revert
            </button>
            {/* Delete permanently -- gated only by the confirmation step
                below, since 0055. Retiring (unticking "In the game" and
                saving) is still the normal, reversible way to take a card
                out of the game; this is the separate, harder-to-reach
                option for a test/mistake row that was never meant to come
                back, and it no longer requires retiring first -- see
                0055_delete_active_cards.sql. */}
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

/**
 * The soft-coded ability/passive editor -- 0049's row-by-row grid replaced
 * for 0056 by the Mad-Libs sentence builder (SentenceBuilder.tsx). A
 * "sentence" is every card_effects row sharing one group_id; a card may
 * hold several, each with its own Ability Type toggle (Active locks the
 * trigger to "When activated" and shows Max Uses/Cooldown; Passive picks
 * any of the other thirteen triggers) -- see this file's own header for the
 * developer's answers this was built from, and card_ability_meta's column
 * comment for why AT MOST ONE Active sentence per card is enforced rather
 * than merely suggested.
 *
 * ITS OWN SAVE BUTTON, same reasoning as the card row's: this table is read
 * by cn_army the moment ANY match starts a new army, and a half-typed value
 * should not be live before Save is pressed.
 *
 * A brand-new, not-yet-saved card has no id for these rows to point at, so
 * the tab says that plainly instead of pretending to be usable.
 */
function AbilityEditor({
  cardId, effects, structures, abilityMeta, busy, err, note,
  onAddSentence, onAddClause, onChangeRow, onRemoveRow,
  onSetTrigger, onSetConditions, onRemoveSentence,
  onSetAbilityType, onSetAbilityMeta, onSave,
}: {
  cardId: string
  effects: CardEffect[]
  structures: { slug: string; name: string }[]
  abilityMeta: CardAbilityMeta[]
  busy: boolean
  err: string | null
  note: string | null
  onAddSentence: () => void
  onAddClause: (groupId: string) => void
  onChangeRow: (rowId: string, patch: Partial<SentenceRow>) => void
  onRemoveRow: (rowId: string) => void
  onSetTrigger: (groupId: string, trigger: string) => void
  onSetConditions: (groupId: string, conditions: CardEffect['conditions']) => void
  onRemoveSentence: (groupId: string) => void
  onSetAbilityType: (groupId: string, isActive: boolean) => void
  onSetAbilityMeta: (groupId: string, patch: Partial<CardAbilityMeta>) => void
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

  const groups = groupSentences(effects)

  return (
    <div className="admin-wide admin-effects">
      <SentenceBuilder
        vocab={cardVocab(structures)}
        groups={groups}
        sentenceNoun="sentence"
        triggerLocked={(groupId) => effects.find((e) => (e.group_id || e.id) === groupId)?.trigger === ACTIVE_TRIGGER}
        triggerLockedLabel="activated"
        onChangeRow={onChangeRow}
        onRemoveRow={onRemoveRow}
        onAddClause={onAddClause}
        onSetTrigger={onSetTrigger}
        onSetConditions={onSetConditions}
        onAddSentence={onAddSentence}
        onRemoveSentence={onRemoveSentence}
        renderSentenceExtra={(groupId, first) => {
          const isActive = first.trigger === ACTIVE_TRIGGER
          const meta = abilityMeta.find((m) => m.group_id === groupId)
          return (
            <div className="sb-sentence-head">
              <div className="admintabs">
                <button
                  type="button" className={isActive ? 'is-on' : ''}
                  onClick={() => onSetAbilityType(groupId, true)}
                >
                  Active
                </button>
                <button
                  type="button" className={isActive ? '' : 'is-on'}
                  onClick={() => onSetAbilityType(groupId, false)}
                >
                  Passive
                </button>
              </div>
              {isActive && (
                <>
                  <label className="sb-cost">
                    <span>Max uses per match</span>
                    <select
                      value={meta?.max_uses != null ? String(meta.max_uses) : ''}
                      onChange={(e) => onSetAbilityMeta(groupId, {
                        max_uses: e.target.value === '' ? null : Number(e.target.value),
                      })}
                    >
                      {MAX_USES_OPTIONS.map((v) => (
                        <option key={v} value={v}>{v === '' ? 'Infinite' : v}</option>
                      ))}
                    </select>
                  </label>
                  <label className="sb-cost">
                    <span>Cooldown (turns)</span>
                    <input
                      type="number" min={0} max={5}
                      value={meta?.cooldown_turns ?? 0}
                      onChange={(e) => onSetAbilityMeta(groupId, { cooldown_turns: Number(e.target.value) })}
                    />
                  </label>
                </>
              )}
            </div>
          )
        }}
      />

      <div className="actionbar admin-acts">
        {/* Its own Save, same reasoning as the header comment above: this table
           is read the moment a match starts. Labelled distinctly from the card
           row's Save just below it -- see that button's own comment. */}
        <button type="button" className="btn primary" disabled={busy} onClick={onSave}>
          {busy ? 'Saving abilities…' : 'Save abilities'}
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
