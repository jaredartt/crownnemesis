import { supabase } from './supabase'
import type { Kingdom, MatchRow, Tourney, Unit } from './types'

/**
 * Every one of these is a call to a Postgres function that validates the move
 * before it touches the board. If a call throws, the server said no — show the
 * message and leave local state alone.
 */

function unwrap<T>(res: { data: T | null; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message.replace(/^.*?:\s*/, ''))
  if (res.data === null) throw new Error('empty response')
  return res.data
}

export async function createMatch(): Promise<MatchRow> {
  return unwrap(await supabase.rpc('create_match').single())
}

export async function joinMatch(code: string): Promise<MatchRow> {
  return unwrap(await supabase.rpc('join_match', { p_code: code.toUpperCase().trim() }).single())
}

export async function submitMove(matchId: string, unitId: string, x: number, y: number) {
  return unwrap(
    await supabase.rpc('submit_move', { p_match: matchId, p_unit: unitId, p_x: x, p_y: y }).single(),
  )
}

export async function submitAttack(matchId: string, unitId: string, targetId: string) {
  return unwrap(
    await supabase
      .rpc('submit_attack', { p_match: matchId, p_unit: unitId, p_target: targetId })
      .single(),
  )
}

/**
 * Raise a guard. It halves everything that lands on this unit until its own
 * next turn -- so it is still up while the opponent is swinging, which is the
 * only time it could matter. It costs the activation and ends it.
 */
export async function submitDefend(matchId: string, unitId: string) {
  return unwrap(
    await supabase.rpc('submit_defend', { p_match: matchId, p_unit: unitId }).single(),
  )
}

/**
 * Close the go of whichever unit is part-way through one. A unit that moved
 * and does not want to strike needs a way to say so, or its go stays open and
 * the second activation cannot start cleanly. Harmless when nobody is mid-go:
 * the server hands the room back unchanged.
 */
export async function submitWait(matchId: string) {
  return unwrap(await supabase.rpc('submit_wait', { p_match: matchId }).single())
}

export async function endTurn(matchId: string) {
  return unwrap(await supabase.rpc('end_turn', { p_match: matchId }).single())
}

export async function resignMatch(matchId: string) {
  return unwrap(await supabase.rpc('resign_match', { p_match: matchId }).single())
}

/** Safe to call from anyone, including spectators. The server ignores it if
 *  the clock has not actually expired. */
export async function forceTimeout(matchId: string) {
  const { error } = await supabase.rpc('force_timeout', { p_match: matchId })
  if (error) console.warn('force_timeout:', error.message)
}

export async function serverNow(): Promise<number> {
  const { data, error } = await supabase.rpc('server_now')
  if (error || !data) return Date.now()
  return new Date(data as string).getTime()
}

/** "I am still in this room." No-op for spectators -- only players hold a
 *  room open, so a match watched by nobody who is playing gets swept. */
export async function touchMatch(matchId: string) {
  const { error } = await supabase.rpc('touch_match', { p_match: matchId })
  if (error) console.warn('touch_match:', error.message)
}

/** Deliberate exit. Deletes the room outright if it just emptied. */
export async function leaveMatch(matchId: string) {
  const { error } = await supabase.rpc('leave_match', { p_match: matchId })
  if (error) console.warn('leave_match:', error.message)
}

/** Safety net for tabs that were closed rather than left. Safe for anyone to
 *  call: it can only remove rooms no player has touched in the grace window. */
export async function sweepMatches() {
  const { error } = await supabase.rpc('sweep_matches')
  if (error) console.warn('sweep_matches:', error.message)
}

/** Ask for a rematch. Returns the new match id once BOTH players have asked,
 *  null while you are still waiting for the other one. */
export async function requestRematch(matchId: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('request_rematch', { p_match: matchId })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data as string | null) ?? null
}

/**
 * Save one kingdom, and hand back the whole list.
 *
 * A SHORT deck is fine and that is deliberate -- see Kingdom in types.ts. The
 * one thing the server refuses is a FINISHED deck that breaks the royal rule,
 * because a deck of five has made its mind up and being told at the moment you
 * finish beats silently fielding something else when the match starts.
 *
 * The id is generated here rather than by the database. It has to exist before
 * the first save so the page can hold an unsaved kingdom open while you decide
 * whether it is going to be one at all.
 */
export async function saveKingdom(
  id: string, name: string | null, icon: string | null, deck: string[],
): Promise<Kingdom[]> {
  const { data, error } = await supabase.rpc('save_kingdom', {
    p_id: id, p_name: name, p_icon: icon, p_deck: deck,
  })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data ?? []) as Kingdom[]
}

/** Hands back what is left. Deleting the one you were fielding lands you on
 *  another rather than on nothing -- the server repoints it. */
export async function deleteKingdom(id: string): Promise<Kingdom[]> {
  const { data, error } = await supabase.rpc('delete_kingdom', { p_id: id })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data ?? []) as Kingdom[]
}

/** Field this one. Returns the id actually selected, which is not always the
 *  one asked for: a selection pointing at nothing lands on the first. */
export async function selectKingdom(id: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('select_kingdom', { p_id: id })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data as string | null) ?? null
}

/** The old door, still open. Writes the SELECTED kingdom. Nothing in this
 *  build calls it any more; it is kept because a tab left open from before
 *  0024 still does. */
export async function setDeck(deck: string[]): Promise<string[]> {
  const { data, error } = await supabase.rpc('set_deck', { p_deck: deck })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return data as string[]
}

/**
 * Move one of your units during deployment. Dropping onto one of your own
 * swaps the two.
 *
 * Returns YOUR units and nothing else, because during this phase the two armies
 * are not in the match row -- your opponent's positions are somewhere you have
 * no permission to look, which is the only way to stop someone reading them
 * out of the network tab and setting up against what they saw.
 */
export async function deployUnit(
  matchId: string, unitId: string, x: number, y: number,
): Promise<Unit[]> {
  const { data, error } = await supabase
    .rpc('deploy_unit', { p_match: matchId, p_unit: unitId, p_x: x, p_y: y })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data ?? []) as Unit[]
}

/** Your own half of a deployment in progress. Null once the match has started,
 *  when both armies are on the board for real. */
export async function myDeploy(matchId: string): Promise<Unit[] | null> {
  const { data, error } = await supabase.rpc('my_deploy', { p_match: matchId })
  if (error) { console.warn('my_deploy:', error.message); return null }
  return (data as Unit[] | null) ?? null
}

/**
 * Which five they brought -- and not one coordinate.
 *
 * Deployment has been blind since 0008, and most of that blindness is the
 * point: WHERE the archer is standing is the secret the phase exists to keep.
 * WHICH FIVE never was, and knowing it is what makes the phase a decision
 * rather than a guess.
 *
 * Null while there is nothing to say: before an opponent arrives, once the
 * match is running (the board shows everything then), and for a spectator --
 * deployment is secret from the room as well as from the other player.
 */
export async function theirArmy(matchId: string): Promise<Unit[] | null> {
  const { data, error } = await supabase.rpc('their_army', { p_match: matchId })
  if (error) { console.warn('their_army:', error.message); return null }
  return (data as Unit[] | null) ?? null
}

/** Lock your half in. The match starts when both players have. */
export async function setReady(matchId: string) {
  return unwrap(await supabase.rpc('set_ready', { p_match: matchId }).single())
}

/** Take the win from an opponent who has gone. The server refuses while their
 *  browser is still sending its heartbeat, so a reload can never lose you a
 *  match -- the message it sends back says exactly that. */
export async function claimWin(matchId: string) {
  return unwrap(await supabase.rpc('claim_win', { p_match: matchId }).single())
}

/** Practice against the machine. A real room with a real board -- the bot
 *  plays through the same Postgres functions your clicks do. */
export async function createBotMatch(level: number): Promise<MatchRow> {
  return unwrap(await supabase.rpc('create_bot_match', { p_level: level }).single())
}

/** Ask the bot for its next single action. Safe for anyone to call: the server
 *  refuses unless it really is a bot match and really is the bot's turn. */
export async function botStep(matchId: string) {
  const { error } = await supabase.rpc('bot_step', { p_match: matchId })
  if (error) console.warn('bot_step:', error.message)
}

export interface QueueState {
  match: string | null
  waiting: number
}

/** Keeps you in the ranked queue and looks for an opponent. Called every
 *  couple of seconds while the queue screen is open; stop calling and you
 *  drop out on your own after twenty-five seconds. */
export async function rankedTick(): Promise<QueueState> {
  const { data, error } = await supabase.rpc('ranked_tick')
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return data as QueueState
}

export async function leaveRanked() {
  const { error } = await supabase.rpc('leave_ranked')
  if (error) console.warn('leave_ranked:', error.message)
}

/** "Not today." Clears both asks, so whoever invited gets their button back
 *  instead of waiting on an answer that is never coming. */
export async function declineRematch(matchId: string) {
  const { error } = await supabase.rpc('decline_rematch', { p_match: matchId })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
}

/** Your icon: one of the roster's own tokens, stored as its slug. The server
 *  checks it is a card that exists, and a trigger checks again on the way in
 *  whichever door it came by. */
export async function setAvatar(slug: string | null): Promise<string | null> {
  const { data, error } = await supabase.rpc('set_avatar', { p_slug: slug })
  if (error) throw error
  return (data as string | null) ?? null
}

/**
 * Save some settings. A PATCH, not the whole blob: the server merges it, so two
 * devices changing different settings do not overwrite one another, and a key
 * this build does not know about is not erased by a build that would never
 * think to send it.
 */
export async function pushSettings(patch: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await supabase.rpc('set_settings', { p_patch: patch })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return data
}

/** Rename yourself. The unique index decides it; this turns the constraint
 *  violation into a sentence. */
export async function setUsername(name: string): Promise<string> {
  const { data, error } = await supabase.rpc('set_username', { p_name: name })
  if (error) throw error
  return data as string
}

/* ---------------------------------------------------------------------------
 * Tournaments.
 *
 * Four calls, and all four return the whole tournament: the server builds the
 * view in one place (tournament_state in 0028) so the screen never has to
 * stitch a bracket together from three tables and guess at the order.
 * ------------------------------------------------------------------------- */

/**
 * The heartbeat, and the referee.
 *
 * It is not only "tell me what is happening". Anybody's tick locks a bracket
 * whose countdown has run out and pushes along any match in it that has
 * stalled -- which is why the tournament page calls it while it is open even
 * when the player is only watching. A bracket whose progress depended on the
 * two people who have stopped playing would never finish. See 0028's header.
 */
export async function tournamentTick(): Promise<Tourney | null> {
  const { data, error } = await supabase.rpc('tournament_tick')
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data as Tourney | null) ?? null
}

export async function tournamentJoin(): Promise<Tourney | null> {
  const { data, error } = await supabase.rpc('tournament_join')
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data as Tourney | null) ?? null
}

/** Sign-ups: leaving takes your name off. Mid-bracket: it is a forfeit, and
 *  the server advances whoever you were playing. Both are the same button and
 *  the screen says which one it is before you press it. */
export async function tournamentLeave(): Promise<Tourney | null> {
  const { data, error } = await supabase.rpc('tournament_leave')
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data as Tourney | null) ?? null
}

/** Skip the countdown. Admins only, and the server is what says so. */
export async function tournamentStartNow(): Promise<Tourney | null> {
  const { data, error } = await supabase.rpc('tournament_start_now')
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data as Tourney | null) ?? null
}

/**
 * Use a unit's ability. It SUBSTITUTES the attack: one activation is still a
 * unit's whole go, so this costs exactly what striking would have and cannot
 * be followed by one.
 *
 * `target` is null for an ability that does not take one -- Back to Back hits
 * everything around it and the Mist hits nowhere in particular.
 */
export async function submitAbility(matchId: string, unitId: string, target: string | null) {
  return unwrap(
    await supabase
      .rpc('submit_ability', { p_match: matchId, p_unit: unitId, p_target: target })
      .single(),
  )
}

/**
 * Answer an open decision: throw the unit the gale has hold of, or let it go.
 *
 * `target` is a tile ('@x,y') or null, and null is also what the clock running
 * out does. Called by the side whose turn it is NOT -- which is the whole
 * novelty of it, and the reason there is no unit argument: the decision names
 * the unit, not the caller.
 */
export async function submitThrow(matchId: string, target: string | null) {
  return unwrap(
    await supabase
      .rpc('submit_throw', { p_match: matchId, p_target: target })
      .single(),
  )
}
