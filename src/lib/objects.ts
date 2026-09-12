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
export type ObjKind = 'tree' | 'wall' | 'bomb' | 'tornado'

/** What it is. An object written before 0035 carries no kind, and is a tree. */
export function objKind(o: Obstacle): ObjKind {
  return (o.kind as ObjKind | undefined) ?? 'tree'
}

/**
 * Does it block feet and arrows?
 *
 * The whole of what separates the kinds as far as the board is concerned. A
 * solid object is walked around and shot around; a non-solid one is walked
 * onto and shot over, which is the point of a trap you are meant to be able
 * to tread on. Mirrors cn_obj_solid().
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
 *  search for the key finds it. */
export function objNameKey(kind: ObjKind): string {
  if (kind === 'wall') return 'obj.wall'
  if (kind === 'bomb') return 'obj.bomb'
  if (kind === 'tornado') return 'obj.tornado'
  return 'obj.tree'
}
