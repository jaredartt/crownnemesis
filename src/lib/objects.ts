import type { Obstacle } from './types'

/**
 * Things that stand on the board and are not units.
 *
 * `obstacles` meant "trees" until 0035 and means "objects" now. This file is
 * the client's half of that migration's vocabulary, and it exists for the same
 * reason effects.ts does: the failure mode is a rule written for trees quietly
 * applying to a trap, and the only defence is that the question is asked in
 * one place. Every function here mirrors one in 0035_summons.sql by name.
 */
// Since 0057: a `kind` is no longer only ever one of four hardcoded values --
// it can be any slug in the structures catalog, exactly like cn_obj_kind's
// own server-side fallback (0057_structures.sql). Kept as a named alias
// rather than every caller just writing `string`, so a search for ObjKind
// still finds every place that cares what kind of thing this is.
export type ObjKind = string

/** What it is. An object written before 0035 carries no kind, and is a tree. */
export function objKind(o: Obstacle): ObjKind {
  return o.kind ?? 'tree'
}

/**
 * Does it block feet and arrows?
 *
 * The whole of what separates the kinds as far as the board is concerned. A
 * solid object is walked around and shot around; a non-solid one is walked
 * onto and shot over, which is the point of a trap you are meant to be able
 * to tread on. Mirrors cn_obj_solid().
 *
 * KNOWN GAP, since 0057: a custom structure's own `blocks_movement` is not
 * read here -- doing that correctly needs the structures catalog threaded
 * through every caller of trees()/losClear()/legalMoves() in rules.ts and
 * rulesRoyale.ts, which is real, separate surgery on the client's most
 * order-sensitive geometry code, not done in this pass. This file's answer
 * for anything past the four legacy kinds is `false` (walked onto, shot
 * over) -- the same "not solid" a caller already got for an unrecognised
 * kind before this migration, so no existing board changes behaviour.
 * `false` is a real answer here, not a crash or a silent wrong tree, and
 * the sole consequence of it being wrong for a `blocks_movement = true`
 * structure is a stale move/LOS *preview* -- the server (cn_obj_solid,
 * read live, never snapshotted) is what every match actually enforces, so
 * the worst case is a rejected move round-trip, not an illegal one that
 * lands. See project_status.md for this gap stated the same way.
 */
export function objSolid(kind: ObjKind): boolean {
  return kind === 'tree' || kind === 'wall'
}

/** Only a TREE is trampled. A wall summoned to stop somebody would be no wall
 *  at all if a trampler walked through it. */
export function objTramplable(kind: ObjKind): boolean {
  return kind === 'tree'
}

/** The i18n key for what this thing is called, written out literally so a
 *  search for the key finds it. Empty for anything 0057 added -- a
 *  structures-catalog slug like 'spike-trap' has no dictionary entry in
 *  either language, and returning 'obj.tree' for one (as this did before
 *  0057) would call a custom structure a Tree in its own tooltip. The
 *  caller falls back to the raw kind when this comes back empty -- see
 *  Board.tsx's ThingBox. Fetching the catalog's own `name` client-side for
 *  a nicer label is a real, separate follow-up (this file's own header on
 *  0057's scope), not done here. */
export function objNameKey(kind: ObjKind): string {
  if (kind === 'wall') return 'obj.wall'
  if (kind === 'bomb') return 'obj.bomb'
  if (kind === 'tornado') return 'obj.tornado'
  if (kind === 'tree') return 'obj.tree'
  return ''
}

/**
 * How far a gale carries, in tiles. Mirrors cn_throw_reach() in 0036.
 *
 * Not on any card, which is why it is a constant here and a function there
 * rather than a column: it is a fact about tornadoes, and there is one
 * tornado.
 */
export const THROW_REACH = 3
