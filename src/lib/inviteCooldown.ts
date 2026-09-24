/**
 * "You can only send one invitation to the same person twice in a row.
 * Then, every there's a cooldown of 10 minutes." (Jared) -- the server is
 * the real rule (send_match_invite rejects a repeat within 10 minutes, see
 * 0089_open_1v1_invites_and_cooldown.sql), so this is only ever UX polish
 * on top of that: a button that visibly can't be pressed again, rather than
 * one that looks live and comes back with an error after the tap. Purely
 * in-memory and per-tab, the same tradeoff Board.tsx's own sfx throttling
 * makes -- a reload forgets it, and the server still catches that case.
 */
const COOLDOWN_MS = 10 * 60 * 1000
const lastSentAt: Record<string, number> = {}

export function noteInviteSent(targetId: string) {
  lastSentAt[targetId] = Date.now()
}

/** Milliseconds left before targetId can be invited again, or 0 if clear. */
export function inviteCooldownMs(targetId: string): number {
  const t = lastSentAt[targetId]
  if (!t) return 0
  return Math.max(0, COOLDOWN_MS - (Date.now() - t))
}
