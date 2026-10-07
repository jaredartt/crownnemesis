/** Crowns (in-game money) and the Shop are switched off for now -- Jared:
 *  "let's not have the shop for now, neither anything that players can't buy,
 *  neither in-game money, so we focus on just the gameplay itself."
 *  Server side, migration 0201 stops Crowns being earned and refuses buy_skin;
 *  this flag hides every Crowns/price control on the client. The Shop page
 *  (Shop.tsx) and its tile were removed outright -- they live in git history
 *  (commit d1e7cce) if it ever comes back. */
export const CROWNS_ENABLED = false

/** Phone push notifications (the gear in the bell window). Live since
 *  2026-10-07: migration 0204, the push_config row and send-push are all in. */
export const PUSH_ENABLED = true
