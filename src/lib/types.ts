export type Side = 'host' | 'guest'

/**
 * One row of the soft-coded ability/passive engine, since 0049. See
 * 0049_card_effects_engine.sql's header for the two-layer design: a PASSIVE
 * row compiles down to a legacy `Card` column (cn_compile_card_effects) and
 * never reaches a unit at runtime; every other trigger is read straight off
 * `Unit.abilityScript` by the server's cn_run_effects.
 *
 * This mirrors the `card_effects` table column for column -- see
 * AbilityEditor.tsx/AdminCards.tsx for the dropdowns that build one, and
 * cn_effect_condition_met (0049) for what `conditions` may hold.
 */
export interface CardEffect {
  id: string
  card_id: string
  sort: number
  trigger: 'ON_PLAY' | 'ON_ABILITY' | 'ON_ATTACK' | 'ON_DEATH' | 'START_OF_TURN'
    | 'END_OF_TURN' | 'ON_PARRY' | 'PASSIVE'
    | 'ON_COUNTER' | 'ON_KILL' | 'ON_HEALED' | 'ON_DAMAGED' | 'ON_STATUS_APPLIED'
  target_selector: 'SELF' | 'NEARBY_ALLIES' | 'ALL_ALLIES' | 'ENEMY_IN_RANGE'
    | 'LOWEST_HP_ENEMY' | 'BOARD_CELL' | 'ALL_ENEMIES' | 'NEAREST_ENEMY'
    | 'HIGHEST_HP_ENEMY' | 'LOWEST_HP_ALLY' | 'HIGHEST_HP_ALLY'
    | 'RANDOM_ENEMY_IN_RANGE' | 'RANDOM_ALLY' | 'ALLIES_IN_LINE'
    | 'ENEMIES_IN_LINE' | 'THE_ATTACKER' | 'THE_TARGET' | 'ADJACENT_UNITS'
  action: 'DEAL_DAMAGE' | 'HEAL' | 'APPLY_STATUS' | 'MODIFY_STAT' | 'PUSH_BACK'
    | 'DRAW_CARD' | 'REMOVE_STATUS' | 'GRANT_EXTRA_ACTIVATION' | 'SUMMON_OBJECT'
    | 'TELEPORT_SELF' | 'SWAP_POSITIONS' | 'REVIVE' | 'COPY_STAT_FROM_TARGET'
    | 'REFLECT_DAMAGE_PCT'
  value?: number | null
  status?: 'NONE' | 'BURNING' | 'STUN' | 'POISON' | 'ANY' | 'ALL' | null
  stat_name?: string | null
  /** An array of {field, op, value}, ALL of which must hold (AND). See
   *  cn_effect_condition_met for the fields/ops the server evaluates. */
  conditions: { field: string; op?: string; value?: string }[]
  created_at?: string
  updated_at?: string
}

export interface Unit {
  id: string
  owner: Side
  cardId: string
  slug: string
  name: string
  /** Swordsmen, Mage, Herbalist... Flavour and a hover heading, nothing more. */
  role: string
  hp: number
  maxHp: number
  mov: number
  /** Reach, in tiles, counting a diagonal as one. Since 0030 rmin is always 1
   *  -- a range of N is every tile from 1 to N, with no hole in the middle --
   *  and a unit answers anything it could have struck, so crmin/crmax follow
   *  rmin/rmax. A unit snapshot carries the four; the single number they are
   *  derived from lives on the card, which is where it is edited. */
  rmin: number
  rmax: number
  crmin: number
  crmax: number
  /** WHAT IT CAN DO, since 0033. `abilityKind` is null for a unit whose card
   *  carries a passive instead -- or nothing at all yet. `abilityN` is the
   *  ability's number (15 damage, 30 healing, 10 per cent) and `abilityTurns`
   *  how long it lasts, where that means anything. */
  abilityKind?: 'aoe_adjacent' | 'heal_any' | 'mist' | 'poison_hit' | 'line_burn'
    | 'summon'
    /** Since 0049: the ability is authored through card_effects rather than
     *  one of the six kinds above -- see `abilityScript` and cn_ability's
     *  'scripted' branch, which dispatches to cn_run_effects(ON_ABILITY). */
    | 'scripted' | null
  /** What a summoner puts down: 'bomb' | 'wall' | 'tornado'. Null for
   *  everybody else, and tied to abilityKind = 'summon' by a check on the
   *  cards table -- a summoner with nothing to summon cannot be saved. */
  summonKind?: 'bomb' | 'wall' | 'tornado' | null
  abilityN?: number | null
  abilityTurns?: number | null
  /** WHAT THIS UNIT'S CARD CAN DO, since 0049 -- every one of its
   *  card_effects rows, copied onto it the moment its army is built
   *  (cn_army) and never re-read from `cards` mid-match, for the same reason
   *  every other stat is snapshotted: a card retuned in the editor must not
   *  change a match already running. Read by the server's cn_run_effects for
   *  ON_PLAY/ON_ABILITY/ON_ATTACK/ON_DEATH/ON_PARRY/START_OF_TURN/
   *  END_OF_TURN. Distinct from `effects` below, which is what is CURRENTLY
   *  on this unit (burn/poison/stun), not what its card can do. Empty or
   *  absent for a unit whose card has no card_effects rows at all -- which,
   *  before 0050, was every card in the game. */
  abilityScript?: CardEffect[]
  /** Passives the engine reads directly rather than through an ability. */
  slippery?: boolean
  twicePct?: number
  regenPct?: number
  dmin: number
  dmax: number
  /** The single number a player reads. The roll is pow +/- 5, and dmin/dmax
   *  are derived from it server-side -- they are the dice, this is the stat.
   *  Optional because a match that was already in flight when 0018 landed has
   *  units in its state blob without it; use unitPower() rather than this. */
  pow?: number
  /** Percent chances, out of 100. 5 for almost everyone. */
  parryPct?: number
  critPct?: number
  /** Catches any answer-to-a-parry aimed at it. */
  parryAll?: boolean
  /** Lose it and you lose the match. A kingdom holds exactly one. */
  royal?: boolean
  burns: boolean
  heals: boolean
  /** Steps over trees and lands where they stood. */
  tramples: boolean
  /** Moves by air: distance only, no walking round anything. */
  flies: boolean
  /** Never takes a counter. */
  sneaks: boolean
  /** Mending also puts a burn out. */
  cures: boolean
  /** Answers BEFORE the blow it is answering. If the answer kills, the blow
   *  never lands at all. */
  parries: boolean
  /** Mending reaches every ally in range, not only the one you clicked. */
  blooms: boolean
  /** Retired by 0034 in favour of `effects.burn`. A match already in flight
   *  when 0034 landed still carries it, which is why it is still read -- see
   *  `isBurning` in lib/effects.ts. Nothing new should set it. */
  burned?: boolean
  /** What is ON this unit, as opposed to what it can do. Burn and poison are
   *  permanent until death; a stun is a countdown of goes it still owes. */
  effects?: {
    burn?: boolean
    poison?: boolean
    stun?: number
  }
  /** Poisons every adjacent unit at the start of its own side's turn. */
  poisonsAdj?: boolean
  /** A landing blow -- including its own answer -- costs the receiver a go. */
  stuns?: boolean
  /** Flat damage added against a POISONED target, after every multiplier. */
  vsPoisoned?: number
  /** Percent of what it deals that it takes back as health. */
  lifestealPct?: number
  /** The royal aura this unit grants its whole side, since F1. Null for
   *  everybody who is not a crown. Read it through awake(): a crown standing
   *  in the swamp grants nothing. */
  auraKind?: string | null
  auraClass?: string | null
  auraPct?: number | null
  /** Umiro. Nearby units -- friend and foe alike -- cannot use passives or
   *  abilities. The one field awake() never strips, because two of them side
   *  by side would otherwise be a paradox with no natural answer. */
  swamps?: boolean
  /** Guard up. Halves what lands on this unit until its OWN next turn, so it
   *  is still standing while the opponent swings -- which is the only moment
   *  it could matter. Raised by submit_defend, dropped by advance_turn. */
  defending?: boolean
  accent: string
  art: string | null
  ability: string
  x: number
  y: number
  moved: boolean
  acted: boolean
  /** This unit has had its whole go this turn and cannot start another.
   *  Optional for the same reason `pow` is: a match already in flight when
   *  0019 landed has units without it. Read it as false when it is missing --
   *  cn_begin_act does exactly that. */
  spent?: boolean
}

/**
 * Something standing on the board that is not a unit.
 *
 * Until 0035 this was only ever a tree, which is why the field on MatchState
 * is still called `obstacles`. Four kinds now, and what separates them is one
 * question -- is it solid? -- asked through lib/objects.ts and nowhere else.
 * An object written before 0035 carries no `kind` at all and is a tree.
 */
export interface Obstacle {
  id: string
  /** 'tree' | 'wall' | 'bomb' | 'tornado'. Absent on a pre-0035 row: read it
   *  through objKind(), never directly. */
  kind?: string
  x: number
  y: number
  hp: number
  maxHp: number
  /** Whose summon it is, and which of their units made it -- a summoner may
   *  have only one standing at a time. Both absent on a tree. */
  owner?: Side
  by?: string
  /** What it takes off whoever steps on it. A trap's fifteen; zero for
   *  everything else. Carried on the object rather than looked up from the
   *  summoner, who may be dead by the time somebody treads on it. */
  dmg?: number
}

export interface LogEntry {
  n: number
  turn: number
  text: string
}

/** Structured record of the last exchange, written by the database so the
 *  clients can animate it without parsing the log text. */
export interface Fx {
  seq: number
  /** 'ability' since 0033. Absent on an ordinary exchange, which is every fx
   *  written before it -- so a client reading an old match sees nothing new. */
  kind?: 'ability'
  /** Which ability it was, when kind is 'ability'. */
  why?: string
  /** One actor, any number of receivers -- the shape an ability needs and an
   *  attack never did. Back to Back lands on everything around it at once. */
  hits?: { id: string; dmg?: number; heal?: number }[]
  atk: string
  tgt: string | null
  dmg: number
  heal: number
  killedTgt: boolean
  counter: number
  killedAtk: boolean
  burnAtk: number
  burnTgt: number
  newBurn: boolean
  /** The mend also put a fire out. */
  cured: boolean
  /** The counter landed first, so the attack may never have happened. */
  parry: boolean
  /** Ids of the allies a bloom swept up besides the one that was clicked. */
  bloom?: string[]
  tree: boolean
  /** These five have been written by the server since 0018 and were simply
   *  missing from this type. The cinematic needs them, and the board's own
   *  little animation would have been entitled to them all along. */
  crit?: boolean
  critCounter?: boolean
  /** Swings caught, and swings swung -- the parry chain, counted. */
  parries?: number
  chain?: number
  /** What the attacker took off in ANSWER to a parry, as opposed to `dmg`,
   *  which is the opening blow. Lium's free hit lands here. */
  riposte?: number
  /** The exchange blow by blow, in the order it happened, from 0020. Absent on
   *  a match that was already in flight when that landed -- read it through
   *  swingsOf() in cine.ts, never directly. */
  swings?: Swing[]
}

/**
 * One thing that happened inside an exchange. Written by cn_attack in
 * 0020_swings.sql; the comment block at the top of that file is the contract.
 *
 * `why` is the field that earns its place: Lium catching an answer because he
 * is Lium ('all') is not the same event as a 5% roll coming up ('roll'), and a
 * caption that calls both of them a parry is labelling rather than narrating.
 */
export interface Swing {
  k: 'hit' | 'parry' | 'burn' | 'down' | 'heal'
  /** Who swung, caught, burned or fell. */
  by: string
  /** Who received it. Equal to `by` for a burn or a falling. */
  at: string
  dmg?: number
  crit?: boolean
  /** It was an answer, so it was already halved. */
  counter?: boolean
  /** The receiver had a guard up, so it was halved again. */
  def?: boolean
  /** It landed BEFORE the blow it answers. Quick Dagger, and nothing else. */
  first?: boolean
  why?: 'strike' | 'counter' | 'quick' | 'tree' | 'mend' | 'roll' | 'all'
    // Since 0033: a blow the mist ate, Himanta's second swing, and a
    // blow an ability landed rather than an exchange.
    | 'mist' | 'twice' | 'ability'
    // Since 0034: a heal a unit took out of what it dealt, and a tile an
    // ability set alight rather than a blow that was swung.
    | 'steal' | 'fire' | 'poison'
}

/**
 * A decision the match is waiting on, belonging to the side whose turn it is
 * NOT. Since 0036 there is exactly one kind: Lumea's gale has hold of somebody
 * and her controller has fifteen seconds to say where they land.
 *
 * While one of these is open NOTHING else may happen -- the server refuses
 * every action with 'a throw is pending' -- and `turn_deadline` is the
 * DECISION's deadline rather than the turn's. What the turn had left is parked
 * in `resumeMs` and handed back when the decision closes.
 */
export interface Pending {
  kind: 'throw'
  /** Whose decision it is. */
  side: Side
  /** The unit the gale has hold of. */
  unit: string
  /** The tornado holding it. */
  obj: string
  /** Milliseconds the turn had left when the decision opened. */
  resumeMs: number
}

export interface MatchState {
  v: number
  board: { w: number; h: number }
  phase: 'deploy' | 'battle'
  ready: Record<Side, boolean>
  obstacles: Obstacle[]
  /** See Pending. Absent, or JSON null, when the match is waiting on nothing
   *  -- which is almost always. */
  pending?: Pending | null
  turn: Side
  turnNumber: number
  /** Activations the side to move has spent this turn, and the unit part-way
   *  through one -- it has moved but has not yet struck, so it may still, and
   *  that costs nothing further. Both from 0019; both absent on an older
   *  match, which is why everything reads them through a default. */
  acts?: number
  active?: string | null
  /** Consecutive turns each side has let expire without touching a unit. */
  idle?: Record<Side, number>
  /** Set once a side reaches three. A fact, not a verdict -- the match keeps
   *  running and the flag clears the moment they act again. */
  away?: Side | null
  units: Unit[]
  log: LogEntry[]
  /** Eva's, one entry per side: how many turns are left and how likely a
   *  Rogue on that side is to be somewhere else when a blow arrives. */
  mist?: Partial<Record<Side, { t: number; pct: number }>>
  winner: Side | null
  fx?: Fx
}

export type MatchStatus = 'waiting' | 'deploying' | 'active' | 'finished'

export interface MatchRow {
  id: string
  code: string
  host_id: string
  guest_id: string | null
  host_name: string
  guest_name: string | null
  status: MatchStatus
  /** 1, 2 or 3 when the guest seat is the bot; null when it is a person. */
  bot: number | null
  /** Only a match found through the queue moves anybody's number. */
  ranked: boolean
  state: MatchState
  turn_deadline: string | null
  winner: Side | null
  created_at: string
  updated_at: string
  rematch_host: boolean
  rematch_guest: boolean
  /** Somebody said no. Cleared by the next invitation, so it is never final. */
  rematch_declined: boolean
  next_match_id: string | null
}

export interface Message {
  id: number
  match_id: string
  user_id: string
  username: string
  body: string
  created_at: string
}

export interface Card {
  id: string
  slug: string
  name: string
  role: string
  hp: number
  mov: number
  /** The card's side of 0033's ability columns. See Unit for what they mean. */
  ability_kind?: string | null
  ability_n?: number | null
  ability_turns?: number | null
  slippery?: boolean
  twice_pct?: number
  regen_pct?: number
  /** The card's side of 0034's effect columns. See Unit for what they mean. */
  poisons_adjacent?: boolean
  stuns?: boolean
  vs_poisoned?: number
  lifesteal_pct?: number
  /** THE reach, and since 0030 the only one of the five anybody sets: N means
   *  every tile from 1 to N, for striking and for answering alike. The four
   *  below are derived from it by cn_check_card on the way in, which is why
   *  the card editor shows one box rather than four with an unwritten
   *  invariant between them. */
  range: number
  rmin: number
  rmax: number
  crmin: number
  crmax: number
  dmin: number
  dmax: number
  /** See Unit.pow. Null only on a card row written before 0018. */
  power: number | null
  parry_pct: number
  crit_pct: number
  parry_all: boolean
  royal: boolean
  burns: boolean
  heals: boolean
  tramples: boolean
  flies: boolean
  sneaks: boolean
  cures: boolean
  parries: boolean
  blooms: boolean
  ability: string
  /** The same sentence in Spanish. Null until somebody writes it, and the
   *  client falls back to English when it is -- see abilityText(). */
  ability_es: string | null
  accent: string
  /** Relative to the site root, e.g. 'cards/dereo.webp'. Run it through
   *  artUrl() before putting it in a src -- the site is not served from /. */
  art_url: string | null
  sort: number
  /** Since 0040. A full public URL into the 'audio' storage bucket, or null
   *  for "no custom sound here" -- which is not a broken card, it is every
   *  card before this migration and most cards after it. customAudio.ts
   *  plays these ALONGSIDE sfx.ts's synthesised sounds, never instead of
   *  them, so a card with nothing set here sounds exactly as it always has. */
  audio_attack_url?: string | null
  audio_ability_url?: string | null
  audio_passive_url?: string | null
  audio_walk_url?: string | null
}

/**
 * One saved army.
 *
 * `deck` MAY BE SHORT. An incomplete kingdom is legal -- building one means
 * sitting at two or three cards for as long as it takes to choose, and a store
 * that will not hold that forgets what you were doing every time you leave the
 * page. Whether a kingdom can actually be FIELDED is a separate question asked
 * at the point of use: `fieldable()` in kingdoms.ts, which mirrors the
 * server's deck_of().
 *
 * `name` is null until somebody names it. The words for "Kingdom 3" belong to
 * whoever is reading, so the client supplies them and the column stays null --
 * a default written into the database would be English in a Spanish account
 * forever.
 */
export interface Kingdom {
  id: string
  name: string | null
  /** A card slug, or null -- the same shape as Profile.avatar. */
  icon: string | null
  deck: string[]
}

export interface Profile {
  id: string
  username: string
  /** A card slug, or null for the plain initial. */
  avatar: string | null
  is_admin: boolean
  lp: number
  wins: number
  losses: number
  games: number
  streak: number
  /** The SELECTED kingdom's deck, kept in step by the server. Still read by
   *  everything written before 0024, which is why it was not retired. */
  deck: string[] | null
  /** Sound, motion, theme -- see settings.ts. Optional because a client can be
   *  one deploy ahead of the database, which here is a normal state rather
   *  than a hypothetical. */
  settings?: Record<string, unknown> | null
  /** Up to ten of them. Optional for the same reason settings is. */
  kingdoms?: Kingdom[] | null
  /** The id of the one being fielded. */
  kingdom?: string | null
  /** Since 0039. Flipped by admin_set_banned(); side_of() stops a banned
   *  account acting in any match the moment this is true, and useAuth.ts
   *  signs the browser itself out within a beat of hearing about it over
   *  Realtime. Optional for the same reason `settings` is: a client one
   *  deploy ahead of the database should not fail to start over a column
   *  that is not there yet. */
  is_banned?: boolean
  /** Since 0039. Free-text badges an admin can set from the Users tab.
   *  Nothing in the game grants one on its own yet -- this is the column
   *  the editor needs to have something to edit, not a finished feature. */
  achievements?: string[]
  /** Since 0045. Four raw counters the achievement catalog checks tiers
   *  against -- see src/lib/achievements.ts. `ranked_wins` mirrors `wins`
   *  from the moment it was added; `wins` itself still means exactly what it
   *  always has (a ranked win), unchanged, because too much already reads it
   *  that way. Optional for the same reason every column added after first
   *  sign-in is: a client one deploy ahead of the database should still
   *  render. */
  bot_wins?: number
  ranked_wins?: number
  crit_count?: number
  parry_count?: number
  /** Up to three achievement ids, shown on this profile and on the VS intro
   *  screen. Set only through set_featured_achievements(), which refuses an
   *  id you have not unlocked. */
  featured_achievements?: string[]
}

export interface LadderRow {
  id: string
  username: string
  /** A card slug, as on Profile. Only actually selected by the view since
   *  0026 -- before that this field was declared and always undefined. */
  avatar: string | null
  /** Phase E's stat. 0 for everybody until tournaments exist; the column is
   *  there so the ladder settles its shape once. */
  tournaments?: number
  lp: number
  tier: string
  wins: number
  losses: number
  games: number
  streak: number
}

/** Mirrors tier_of() in 0004_ladder.sql. Display only -- the server owns the
 *  floors -- but if you change the thresholds, change them in both places. */
export const TIERS = [
  { at: 1500, name: 'Crown' },
  { at: 1200, name: 'Diamond' },
  { at: 900, name: 'Platinum' },
  { at: 600, name: 'Gold' },
  { at: 300, name: 'Silver' },
  { at: 0, name: 'Bronze' },
] as const

export const tierOf = (lp: number) => TIERS.find((t) => lp >= t.at)!.name

/** A turn is two activations, and one activation is one unit's whole go --
 *  move, then strike, or either alone. Mirrors cn_acts_cap() in
 *  0019_board_and_actions.sql: the opening turn of a match gets ONE, because
 *  going first with a full turn is worth too much on a board this size. It
 *  reads <= 1 rather than === 1 so a match from before that migration, which
 *  may carry no turnNumber at all, is treated as opening rather than as
 *  unlimited -- the same fallback the server takes. */
export const ACTS_PER_TURN = 2
export const actsCap = (s: { turnNumber?: number }) =>
  (s.turnNumber ?? 1) <= 1 ? 1 : ACTS_PER_TURN

export const TURN_SECONDS = 30
export const DEPLOY_SECONDS = 90
export const DECK_SIZE = 5
export const AWAY_TURNS = 3

/** The three difficulties. The level is the number the server wants; the key
 *  is the name of the words, which live in the dictionary now -- CALM, SHARP
 *  and RUTHLESS are as much a translation as any other sentence, and having
 *  them here as well would be two places to change one. */
export const BOT_LEVELS = [
  { level: 1, key: 'calm' },
  { level: 2, key: 'sharp' },
  { level: 3, key: 'ruthless' },
] as const

/**
 * A range reads as ONE number, because since 0030 that is what it is: N means
 * every tile from 1 to N, for striking and for answering alike. The band form
 * is kept for a low end above 1, which nothing has any more -- a card that
 * grew one would be a rule change, and a rule change should show up on screen
 * rather than be rounded off by the formatter that prints it.
 */
export const reachText = (lo: number, hi: number) =>
  (lo <= 1 ? `${hi}` : lo === hi ? `${lo}` : `${lo}–${hi}`)

/** The single number to print for a unit or a card. Falls back to the middle
 *  of the old band, which is exactly how 0018 derived `power` in the first
 *  place -- so a match still running from before the migration reads the same
 *  number it would have been given. */
export function unitPower(u: { pow?: number | null; power?: number | null; dmin: number; dmax: number }): number {
  const p = u.pow ?? u.power
  return p ?? Math.round((u.dmin + u.dmax) / 2)
}

/* ---------------------------------------------------------------------------
 * Tournaments. The shape of what tournament_state() returns in 0028, and
 * nothing more: the client draws this, it does not compute it. Which round a
 * player is in, whose match is whose and where the byes fell were all decided
 * on the server when the bracket locked, and re-deriving any of it here would
 * be a second implementation of the same rules waiting to disagree.
 * ------------------------------------------------------------------------- */

export type TourneyStatus = 'open' | 'running' | 'finished'

export interface TourneyEntry {
  id: string
  name: string
  avatar: string | null
  lp: number
  /** Null until the bracket locks -- seeds do not exist before then. */
  seed: number | null
  out: boolean
}

/** One slot of the bracket, won or waiting. `aId`/`bId` are null while the
 *  match that feeds them is still being played. */
export interface TourneySlot {
  id: string
  round: number
  slot: number
  aId: string | null
  aName: string | null
  bId: string | null
  bName: string | null
  /** The real match, once there is one to play or watch. */
  match: string | null
  winnerId: string | null
  winnerName: string | null
  /** Nobody was there to play: a win that had already happened when the
   *  bracket locked. */
  bye: boolean
}

export interface Tourney {
  id: string
  status: TourneyStatus
  /** When the bracket locks. Null until the third entrant arrives, and null
   *  again once it has locked. */
  locksAt: string | null
  startedAt: string | null
  finishedAt: string | null
  /** The power of two the bracket was drawn at, and how many rounds that is.
   *  Null while sign-ups are still open. */
  size: number | null
  rounds: number | null
  winnerId: string | null
  winnerName: string | null
  /** The server's clock, so a countdown does not drift with a wrong watch. */
  now: string
  entries: TourneyEntry[]
  bracket: TourneySlot[]
  me: {
    in: boolean
    out: boolean
    seed: number | null
    /** The match you are meant to be playing right now, if any. */
    match: string | null
  }
}

/* ---------------------------------------------------------------------------
 * Admin Mode -- 0039 through 0042
 * ------------------------------------------------------------------------- */

/** One row of a Menu or Battle playlist. See 0041_music.sql. */
export interface MusicTrack {
  id: string
  category: 'menu' | 'battle'
  title: string
  /** A full public URL into the 'audio' storage bucket. */
  url: string
  sort: number
  is_active: boolean
}

/** The single row 0041 keeps the two shuffle toggles on. */
export interface MusicSettings {
  menu_shuffle: boolean
  battle_shuffle: boolean
}

/** One tile's visibility and place in the menu grid, live from the database.
 *  See 0042_menu_sections.sql -- `id` matches a PageId in Lobby.tsx.
 *  The four `*_en`/`*_es` fields are since 0046: an admin-written override
 *  for the tile's headline and its one-line note, in each language. Null
 *  means "nothing written, use the built-in dictionary key" -- see
 *  Lobby.tsx (reads them) and AdminMenu.tsx (writes them). */
export interface MenuSection {
  id: string
  visible: boolean
  sort: number
  title_en: string | null
  title_es: string | null
  subtitle_en: string | null
  subtitle_es: string | null
}

/** One overridden i18n key, since 0046_admin_content_and_delete.sql. `key`
 *  is an existing literal key from src/i18n/en.json (e.g. 'lobby.ranked') --
 *  src/lib/i18n.ts's translate() checks this table before falling back to
 *  the bundled dictionary, so a row here replaces that string everywhere it
 *  is read through t(), in both languages, with no deploy. See
 *  useContentOverrides.ts and AdminMenu.tsx's "Content overrides" tab. */
export interface ContentOverride {
  key: string
  value_en: string
  value_es: string
}

/** See 0043_friends.sql. One row per direction -- `friend_requests` is the
 *  handshake and never the friendship itself; `friends` (below) is that. */
export interface FriendRequestRow {
  id: string
  from_id: string
  to_id: string
  status: 'pending' | 'accepted' | 'declined'
  created_at: string
  updated_at: string
}

/** One direction of an accepted friendship. Always comes in a pair -- A->B
 *  and B->A -- so reading "my friends" never needs an OR across columns. */
export interface FriendRow {
  user_id: string
  friend_id: string
  created_at: string
}

/** One row per account, touched every ~20s while the app is open. "Online"
 *  is not a column -- it is `Date.now() - seen_at < 30s`, worked out on the
 *  client the same way match_presence's grace window always has been. */
export interface UserPresenceRow {
  user_id: string
  seen_at: string
}

/** See 0044_notifications.sql. `payload` is one of a few shapes depending on
 *  `type` -- read it with `??` for every field, the same caution the rest of
 *  this file already uses for anything that came out of jsonb. */
export interface NotificationRow {
  id: string
  user_id: string
  type: 'friend_request' | 'match_invite' | 'friend_accepted'
  payload: {
    request_id?: string
    from_id?: string
    from_username?: string
    by_id?: string
    by_username?: string
    mode?: '1v1' | '4p' | 'tournament'
    match_id?: string
    code?: string
    tournament_id?: string
  }
  read: boolean
  created_at: string
}

/**
 * See 0048_battle_royale.sql. Battle Royale is a separate 4-seat sibling of
 * the 1v1 match above -- its own tables (royale_matches/royale_players/
 * royale_messages), its own RPCs, no ranked/ELO/achievements. A royale unit
 * is shaped exactly like a 1v1 Unit except `owner` is the seat (0-3) that
 * placed it rather than 'host'|'guest' -- every combat field, passive and
 * stat is copied onto it the same way cn_army does for a 1v1 unit, because
 * cn_attack_royale is a direct port of cn_attack and reads the same fields.
 */
export type RoyaleUnit = Omit<Unit, 'owner'> & { owner: number }

export type RoyaleStatus = 'waiting' | 'deploying' | 'active' | 'finished'

/** The board during royale's lobby/deploy/battle phases. Unlike 1v1 there is
 *  no hidden half: every seat's placement is visible in this one shared blob
 *  as soon as it is made (see the migration header's "deployment hiding"
 *  note) -- `pendingUnits` is keyed by seat number as a string ('0'..'3') and
 *  only present during the 'deploy' phase, cleared once everyone is ready. */
export interface RoyaleMatchState {
  v: number
  board: { w: number; h: number }
  phase: 'lobby' | 'deploy' | 'battle'
  obstacles: Obstacle[]
  units: RoyaleUnit[]
  pendingUnits?: Record<string, RoyaleUnit[]>
  /** The seat to act, or null before the battle opens. */
  turn: number | null
  turnNumber: number
  acts?: number
  active?: string | null
  log: LogEntry[]
  winnerSeat: number | null
}

export interface RoyaleMatchRow {
  id: string
  code: string
  status: RoyaleStatus
  state: RoyaleMatchState
  turn_deadline: string | null
  winner_seat: number | null
  created_at: string
  updated_at: string
}

/** One seated player. Rows for empty seats simply do not exist -- a match
 *  with two people in it has two rows, not four with two blank. */
export interface RoyalePlayerRow {
  match_id: string
  seat: number
  user_id: string | null
  username: string
  avatar: string | null
  eliminated: boolean
  eliminated_at: string | null
  ready: boolean
  last_acted_turn: number | null
  seen_at: string
  joined_at: string
}

export interface RoyaleMessage {
  id: number
  match_id: string
  user_id: string
  username: string
  body: string
  created_at: string
}
