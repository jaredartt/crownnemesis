import { supabase } from './supabase'
import type {
  AdminBanAppealRow, BanAppeal, FriendRequestRow, Kingdom, MatchRow, NotificationRow, Profile,
  RoyaleMatchRow, RoyaleUnit, Tourney, Unit,
} from './types'

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
 * Raise a guard on `targetId` -- self, any unit (ally or enemy), or any
 * structure, so long as it is within range 1 of the acting unit. Halves
 * everything that lands on the defended thing until the RAISER's own next
 * turn -- so it is still up while the opponent is swinging, which is the
 * only time it could matter. It costs the activation and ends it. Since
 * 0096: retargetable (`submit_defend`'s own 3-arg overload); pass the
 * acting unit's own id to defend itself.
 */
export async function submitDefend(matchId: string, unitId: string, targetId: string) {
  return unwrap(
    await supabase
      .rpc('submit_defend', { p_match: matchId, p_unit: unitId, p_target: targetId })
      .single(),
  )
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

/** The one row finish_match() ever writes for a given match (see
 *  0004_ladder.sql, rewritten by 0082_raw_rating_system.sql) -- winner_lp
 *  is always >= 0 (what the winner gained) and loser_lp always <= 0 (what
 *  the loser lost); since 0082 these are a highly volatile Elo swing, not
 *  a floor-protected one, but the sign convention and the columns
 *  themselves are unchanged, so nothing that already read them broke. The
 *  four rating columns are 0082's addition -- the absolute before/after
 *  numbers ("1200 -> 1215") the winner_lp/loser_lp swing alone can't show.
 *  Absent for a bot match, and for a friend-room or tournament match while
 *  the admin's LP-from-friends-and-tournaments toggle is off --
 *  finish_match is never called for those, so there is nothing here to
 *  read. RLS ("results readable") lets any signed-in player read any row,
 *  so this needs no id of its own to check against -- matches.code is
 *  unique per match, rematches included, since each one is minted fresh by
 *  gen_match_code(). */
export interface MatchResult {
  winner_id: string | null
  loser_id: string | null
  winner_name: string
  loser_name: string
  winner_lp: number
  loser_lp: number
  winner_rating_before: number | null
  winner_rating_after: number | null
  loser_rating_before: number | null
  loser_rating_after: number | null
  reason: 'defeat' | 'resign' | 'abandon'
}
export async function getMatchResult(code: string): Promise<MatchResult | null> {
  const { data, error } = await supabase
    .from('match_results')
    .select(
      'winner_id, loser_id, winner_name, loser_name, winner_lp, loser_lp, winner_rating_before, winner_rating_after, loser_rating_before, loser_rating_after, reason',
    )
    .eq('code', code)
    .order('created_at', { ascending: false })
    .limit(1)
  if (error) { console.warn('match_results:', error.message); return null }
  return data && data.length > 0 ? (data[0] as MatchResult) : null
}

/** A player's raw ranked rating (0082_raw_rating_system.sql) -- 1000 for
 *  anyone who has never finished a rated game, since player_rating has no
 *  row for them yet (finish_match inserts one on that player's first
 *  finish, not before). RLS ("rating readable") is `using (true)` since
 *  0082, the same as the ladder itself, so this needs no id check either. */
export async function getRating(userId: string): Promise<number> {
  const { data, error } = await supabase
    .from('player_rating').select('rating').eq('user_id', userId).maybeSingle()
  if (error) { console.warn('player_rating:', error.message); return 1000 }
  return data?.rating ?? 1000
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

/** 0060: your name's color, everywhere your name shows to somebody else.
 *  The nine options live in lib/nameColors.ts; the server checks again
 *  regardless (a CHECK constraint, not just this call). */
export async function setNameColor(color: string): Promise<string> {
  const { data, error } = await supabase.rpc('set_name_color', { p_color: color })
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

/* ---------------------------------------------------------------------------
 * Admin Mode -- User & Security Management (0039)
 *
 * Both of these are `security definer` functions that re-check
 * cn_is_super_admin() themselves; nothing about calling them from here makes
 * them any less locked than they are in the database. See
 * 0039_super_admin.sql for what each one actually does and refuses.
 * ------------------------------------------------------------------------- */

export interface AdminProfilePatch {
  id: string
  username?: string
  avatar?: string | null
  clearAvatar?: boolean
  wins?: number
  losses?: number
  games?: number
  streak?: number
  achievements?: string[]
  // 0100: the "won cups" number (profiles.tournaments) -- now editable
  // from AdminUsers, same as every other stat here.
  tournaments?: number
}

export async function adminUpdateProfile(p: AdminProfilePatch): Promise<Profile> {
  return unwrap(
    await supabase
      .rpc('admin_update_profile', {
        p_user: p.id,
        p_username: p.username ?? null,
        p_avatar: p.avatar ?? null,
        p_avatar_clear: p.clearAvatar ?? false,
        p_wins: p.wins ?? null,
        p_losses: p.losses ?? null,
        p_games: p.games ?? null,
        p_streak: p.streak ?? null,
        p_achievements: p.achievements ?? null,
        p_tournaments: p.tournaments ?? null,
      })
      .single(),
  )
}

export async function adminSetBanned(userId: string, banned: boolean): Promise<Profile> {
  return unwrap(
    await supabase.rpc('admin_set_banned', { p_user: userId, p_banned: banned }).single(),
  )
}

/** 0082: sets a player's raw ranked rating directly. A separate function
 *  rather than a ninth admin_update_profile() param -- rating lives in
 *  player_rating now, not on the profiles row that one returns, and
 *  admin_set_rating re-checks cn_is_super_admin() itself the same as every
 *  other admin RPC here. */
export async function adminSetRating(userId: string, rating: number): Promise<number> {
  const { data, error } = await supabase.rpc('admin_set_rating', { p_user: userId, p_rating: rating })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data as number | null) ?? rating
}

/* ---------------------------------------------------------------------------
 * Ban appeals -- 0062. The account's own two calls, then the admin's two.
 * ------------------------------------------------------------------------- */

export async function submitBanAppeal(message: string): Promise<BanAppeal> {
  return unwrap(
    await supabase.rpc('submit_ban_appeal', { p_message: message }).single(),
  )
}

export async function myBanAppeals(): Promise<BanAppeal[]> {
  const { data, error } = await supabase.rpc('my_ban_appeals')
  if (error) { console.warn('my_ban_appeals:', error.message); return [] }
  return (data ?? []) as BanAppeal[]
}

export async function adminListBanned(): Promise<Profile[]> {
  const { data, error } = await supabase.rpc('admin_list_banned')
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data ?? []) as Profile[]
}

export async function adminListBanAppeals(): Promise<AdminBanAppealRow[]> {
  const { data, error } = await supabase.rpc('admin_list_ban_appeals')
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data ?? []) as AdminBanAppealRow[]
}

export async function adminResolveBanAppeal(
  id: string, approve: boolean, note?: string,
): Promise<BanAppeal> {
  return unwrap(
    await supabase
      .rpc('admin_resolve_ban_appeal', { p_id: id, p_approve: approve, p_note: note ?? null })
      .single(),
  )
}

/* ---------------------------------------------------------------------------
 * Achievements -- 0045
 * ------------------------------------------------------------------------- */

/** One other player's face and name, as the VS intro screen needs them --
 *  and nothing else off their profile. A direct table read rather than an
 *  RPC, the same as AdminUsers reads `cards` and `profiles` today: the row
 *  is already readable by anyone signed in (see 0045's RLS), so there is no
 *  validating to do on the way out. */
export interface MatchIntroProfile {
  id: string
  avatar: string | null
  featured_achievements: string[]
  /** 0060: matches.host_name/guest_name are a frozen snapshot (see that
   *  table's own comment); name_color deliberately is NOT one more frozen
   *  column beside them -- it rides this same live-by-id fetch instead, so
   *  a color picked mid-match still shows before the match ends. */
  name_color: string | null
}

export async function getMatchIntroProfiles(
  ids: string[],
): Promise<Record<string, MatchIntroProfile>> {
  if (ids.length === 0) return {}
  const { data, error } = await supabase
    .from('profiles')
    .select('id, avatar, featured_achievements, name_color')
    .in('id', ids)
  if (error || !data) { console.warn('getMatchIntroProfiles:', error?.message); return {} }
  const out: Record<string, MatchIntroProfile> = {}
  for (const row of data as MatchIntroProfile[]) out[row.id] = row
  return out
}

/** Bragging rights for the VS screen -- Jared: "if rematches happen... say
 *  something like it has a 1 win streak against that person". `leaderId`
 *  is whoever won their most recent meeting; `streak` is how many of their
 *  last meetings in a row (walking back from that one) the SAME person
 *  took. A direct read off match_results, same reasoning as
 *  getMatchIntroProfiles just above -- it's readable by anyone signed in
 *  (see 0004_ladder.sql's own "results readable" policy) and the walk is
 *  cheap enough client-side off a short page of rows that an RPC would
 *  only be one more thing to keep in sync with this file. */
export interface HeadToHead {
  leaderId: string
  streak: number
}

export async function getHeadToHead(a: string, b: string): Promise<HeadToHead | null> {
  const { data, error } = await supabase
    .from('match_results')
    .select('winner_id, loser_id, created_at')
    .or(`and(winner_id.eq.${a},loser_id.eq.${b}),and(winner_id.eq.${b},loser_id.eq.${a})`)
    .order('created_at', { ascending: false })
    .limit(20)
  if (error || !data || data.length === 0) {
    if (error) console.warn('getHeadToHead:', error.message)
    return null
  }
  const leaderId = (data[0] as { winner_id: string }).winner_id
  let streak = 0
  for (const row of data as { winner_id: string }[]) {
    if (row.winner_id !== leaderId) break
    streak += 1
  }
  return { leaderId, streak }
}

/** Every achievement id this account has ever unlocked. Fetched once when
 *  the achievements section of the profile card opens -- not cached, and not
 *  folded into `Profile`, because the counters on `Profile` (bot_wins and
 *  the rest) are cheap to carry everywhere but the unlock rows are their own
 *  table for a reason: there can be dozens of them and only one screen ever
 *  reads all of them at once. */
export async function getUnlockedAchievements(userId: string): Promise<string[]> {
  const { data, error } = await supabase
    .from('player_achievements')
    .select('achievement_id')
    .eq('user_id', userId)
  if (error || !data) { console.warn('getUnlockedAchievements:', error?.message); return [] }
  return (data as { achievement_id: string }[]).map((r) => r.achievement_id)
}

/** Choose up to three unlocked achievements to show on your profile and on
 *  the VS intro screen. The server refuses an id you have not unlocked --
 *  see set_featured_achievements() in 0045_achievements.sql. */
export async function setFeaturedAchievements(ids: string[]): Promise<void> {
  const { error } = await supabase.rpc('set_featured_achievements', { p_ids: ids })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
}

/**
 * The real, permanent delete -- see admin_delete_card() in
 * 0084_admin_delete_card_clears_decks.sql for the one check it still runs
 * (not on the board in an unfinished match) and what it cleans up
 * automatically instead of refusing (any deck or saved kingdom fielding the
 * card), and AdminCards.tsx for the confirm step in front of this call.
 *
 * Not run through unwrap(): the function returns void, so `.single()` would
 * have nothing to unwrap and unwrap() would read that as the empty-response
 * error rather than as success. A thrown error is still the server's own
 * sentence, verbatim -- the same treatment every other admin write here
 * gives one.
 */
export async function adminDeleteCard(id: string): Promise<void> {
  const { error } = await supabase.rpc('admin_delete_card', { p_id: id })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
}

// 0057: the structures catalog's own delete, same shape as
// adminDeleteCard -- see admin_delete_structure() in
// 0057_structures.sql for the one check it makes (not standing as an
// obstacle in any unfinished match) before the row goes.
export async function adminDeleteStructure(id: string): Promise<void> {
  const { error } = await supabase.rpc('admin_delete_structure', { p_id: id })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
}

// ---------------------------------------------------------------------------
// Friends & invites -- see 0043_friends.sql.
// ---------------------------------------------------------------------------

export async function sendFriendRequest(toId: string): Promise<FriendRequestRow> {
  return unwrap(await supabase.rpc('send_friend_request', { p_to: toId }).single())
}

export async function respondFriendRequest(id: string, accept: boolean) {
  const { error } = await supabase.rpc('respond_friend_request', { p_id: id, p_accept: accept })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
}

export async function removeFriend(friendId: string) {
  const { error } = await supabase.rpc('remove_friend', { p_friend: friendId })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
}

/** "I am still somewhere in the app." Called every ~20s while signed in --
 *  see the interval in App.tsx -- the same shape touchMatch() already is for
 *  one room, just for the whole session instead. */
export async function touchPresence() {
  const { error } = await supabase.rpc('touch_presence')
  if (error) console.warn('touch_presence:', error.message)
}

export async function sendMatchInvite(toId: string, mode: '1v1' | '4p' | 'tournament'): Promise<string> {
  const { data, error } = await supabase.rpc('send_match_invite', { p_to: toId, p_mode: mode })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return data as string
}

// ---------------------------------------------------------------------------
// Notifications -- see 0044_notifications.sql.
// ---------------------------------------------------------------------------

/** Newest first. The server sweeps this account's own stale rows (48h) as
 *  part of the same call -- see the migration's comment on why that is lazy
 *  rather than a cron job. */
export async function fetchNotifications(): Promise<NotificationRow[]> {
  const { data, error } = await supabase.rpc('fetch_notifications')
  if (error) { console.warn('fetch_notifications:', error.message); return [] }
  return (data ?? []) as NotificationRow[]
}

export async function markNotificationRead(id: string) {
  const { error } = await supabase.rpc('mark_notification_read', { p_id: id })
  if (error) console.warn('mark_notification_read:', error.message)
}

export async function markAllNotificationsRead() {
  const { error } = await supabase.rpc('mark_all_notifications_read')
  if (error) console.warn('mark_all_notifications_read:', error.message)
}

// ---------------------------------------------------------------------------
// Battle Royale (0048_battle_royale.sql) -- a separate 4-seat sibling of the
// 1v1 calls above. Same unwrap() convention; same "the server is the
// authority" shape.
// ---------------------------------------------------------------------------

export async function createRoyaleMatch(): Promise<RoyaleMatchRow> {
  return unwrap(await supabase.rpc('create_royale_match').single())
}

export async function joinRoyaleMatch(code: string): Promise<RoyaleMatchRow> {
  return unwrap(
    await supabase.rpc('join_royale_match', { p_code: code.toUpperCase().trim() }).single(),
  )
}

/** Host-only (seat 0). The server allows starting with as few as two seated
 *  -- see the migration header -- so this is safe to offer as soon as a
 *  second player has joined. */
export async function startRoyaleMatch(matchId: string): Promise<RoyaleMatchRow> {
  return unwrap(await supabase.rpc('start_royale_match', { p_match: matchId }).single())
}

// ---------------------------------------------------------------------------
// Bots in Battle Royale (0052_royale_bots.sql).
// ---------------------------------------------------------------------------

/** Host-only, and only while the room is still 'waiting'. `level` is the
 *  same 1/2/3 CALM/SHARP/RUTHLESS scale as BOT_LEVELS/createBotMatch. */
export async function addRoyaleBot(
  matchId: string, seat: number, level: number,
): Promise<RoyaleMatchRow> {
  return unwrap(
    await supabase.rpc('add_royale_bot', { p_match: matchId, p_seat: seat, p_level: level })
      .single(),
  )
}

/** Host-only, and only on a seat that is actually a bot. */
export async function removeRoyaleBot(matchId: string, seat: number): Promise<RoyaleMatchRow> {
  return unwrap(
    await supabase.rpc('remove_royale_bot', { p_match: matchId, p_seat: seat }).single(),
  )
}

/** The Vs Bots menu's royale entry: seats the caller at 0 and fills seats
 *  1..levels.length with bots at the given difficulties (1-3 opponents,
 *  never forced to exactly three), then starts the match the same way the
 *  host's own "Start match" button does. */
export async function createRoyaleBotMatch(levels: number[]): Promise<RoyaleMatchRow> {
  return unwrap(await supabase.rpc('create_royale_bot_match', { p_levels: levels }).single())
}

/** The royale sibling of botStep() below -- one bot decision per call. See
 *  RoyaleMatch.tsx's driving effect, the exact pattern Match.tsx already
 *  uses for the 1v1 bot. */
export async function royaleBotStep(matchId: string, seat: number) {
  const { error } = await supabase.rpc('royale_bot_step', { p_match: matchId, p_seat: seat })
  if (error) console.warn('royale_bot_step:', error.message)
}

/**
 * Reposition a unit inside your own pending army, before Ready.
 *
 * Returns YOUR units and nothing else (0054_royale_deploy_fog.sql) -- the
 * other seats' placements now live in rows this client has no permission to
 * read, the same guarantee deployUnit() has always given 1v1.
 */
export async function deployRoyaleUnit(
  matchId: string, unitId: string, x: number, y: number,
): Promise<RoyaleUnit[]> {
  const { data, error } = await supabase
    .rpc('deploy_royale_unit', { p_match: matchId, p_unit_id: unitId, p_x: x, p_y: y })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data ?? []) as RoyaleUnit[]
}

/** Your own pending army during royale deployment, or null once the battle
 *  has opened for real -- the royale sibling of myDeploy(). */
export async function myRoyaleDeploy(matchId: string): Promise<RoyaleUnit[] | null> {
  const { data, error } = await supabase.rpc('my_royale_deploy', { p_match: matchId })
  if (error) { console.warn('my_royale_deploy:', error.message); return null }
  return (data as RoyaleUnit[] | null) ?? null
}

/** Lock your placement in. The battle opens once every seated player has. */
export async function setRoyaleReady(matchId: string): Promise<RoyaleMatchRow> {
  return unwrap(await supabase.rpc('set_royale_ready', { p_match: matchId }).single())
}

export async function submitRoyaleMove(
  matchId: string, unitId: string, x: number, y: number,
): Promise<RoyaleMatchRow> {
  return unwrap(
    await supabase.rpc('submit_royale_move', { p_match: matchId, p_unit: unitId, p_x: x, p_y: y })
      .single(),
  )
}

export async function submitRoyaleAttack(
  matchId: string, unitId: string, targetId: string,
): Promise<RoyaleMatchRow> {
  return unwrap(
    await supabase
      .rpc('submit_royale_attack', { p_match: matchId, p_unit: unitId, p_target: targetId })
      .single(),
  )
}

export async function submitRoyaleDefend(matchId: string, unitId: string): Promise<RoyaleMatchRow> {
  return unwrap(
    await supabase.rpc('submit_royale_defend', { p_match: matchId, p_unit: unitId }).single(),
  )
}

export async function submitRoyaleAbility(
  matchId: string, unitId: string, target: string | null,
): Promise<RoyaleMatchRow> {
  return unwrap(
    await supabase
      .rpc('submit_royale_ability', { p_match: matchId, p_unit: unitId, p_target: target })
      .single(),
  )
}

export async function endRoyaleTurn(matchId: string): Promise<RoyaleMatchRow> {
  return unwrap(await supabase.rpc('submit_royale_end_turn', { p_match: matchId }).single())
}

/** "I am still in this room." No-op for spectators. */
export async function touchRoyaleMatch(matchId: string) {
  const { error } = await supabase.rpc('touch_royale_match', { p_match: matchId })
  if (error) console.warn('touch_royale_match:', error.message)
}

/** Deliberate exit. Deletes the room outright if it just emptied and nobody
 *  has placed a unit yet. */
export async function leaveRoyaleMatch(matchId: string) {
  const { error } = await supabase.rpc('leave_royale_match', { p_match: matchId })
  if (error) console.warn('leave_royale_match:', error.message)
}

/** Safety net for tabs closed rather than left, same shape as sweepMatches. */
export async function sweepRoyaleMatches() {
  const { error } = await supabase.rpc('sweep_royale_matches')
  if (error) console.warn('sweep_royale_matches:', error.message)
}

/** Royale's answer to forceTimeout above -- safe to call from anyone,
 *  including spectators. The server ignores it if the clock has not
 *  actually expired. See 0051_afk_and_stalemate.sql. */
export async function forceTimeoutRoyale(matchId: string) {
  const { error } = await supabase.rpc('force_timeout_royale', { p_match: matchId })
  if (error) console.warn('force_timeout_royale:', error.message)
}

export async function sendRoyaleMessage(matchId: string, body: string) {
  const { error } = await supabase.rpc('send_royale_message', { p_match: matchId, p_body: body })
  if (error) console.warn('send_royale_message:', error.message)
}
