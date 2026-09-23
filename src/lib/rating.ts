/**
 * The client-side mirror of cn_elo_k()/finish_match()'s Elo math in
 * 0082_raw_rating_system.sql -- kept in sync by hand, the same way
 * types.ts's TURN_SECONDS/ACTS_PER_TURN mirror their own server constants.
 * Nothing on the client actually moves a rating (only finish_match does,
 * server-side, inside the one transaction that also updates wins/losses/
 * streak) -- this is for showing someone a number before it happens: the
 * admin K-factor editor's live preview, today, and anywhere else a "what
 * would this game do to my rating" preview is useful later.
 *
 * A highly volatile standard Elo, not Glicko-2 -- Jared's call for a pool
 * this small: with well under ten concurrent players, a rating deviation
 * term has almost nothing to average over and converges no faster than a
 * plain high-K Elo does, for a lot more code.
 */

/** Win probability for a player rated `a` against a player rated `b`.
 *  Mirrors expected_score() in 0004_ladder.sql exactly. */
export function expectedScore(a: number, b: number): number {
  return 1 / (1 + Math.pow(10, (b - a) / 400))
}

/** The K-factor a player with `games` finished ranked games draws --
 *  `placement` while `games < placementGames`, `established` after.
 *  Mirrors cn_elo_k() in 0082_raw_rating_system.sql. */
export function eloK(
  games: number,
  k: { placement: number; established: number; placementGames: number },
): number {
  return games < k.placementGames ? k.placement : k.established
}

/** The new rating for a player rated `rating`, `games` games in, who just
 *  won (`won: true`) or lost (`won: false`) against an opponent rated
 *  `opponentRating`. Mirrors finish_match()'s w_rating_new/l_rating_new. */
export function nextRating(
  rating: number,
  opponentRating: number,
  won: boolean,
  games: number,
  k: { placement: number; established: number; placementGames: number },
): number {
  const e = expectedScore(rating, opponentRating)
  const factor = eloK(games, k)
  const delta = factor * ((won ? 1 : 0) - e)
  return Math.round(rating + delta)
}
