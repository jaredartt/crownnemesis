import type { RoyaleMatchState, RoyaleUnit } from '../lib/types'
import type { RoyaleTarget } from '../lib/rulesRoyale'
import { rkey, royaleZone } from '../lib/rulesRoyale'
import { objKind } from '../lib/objects'

const SEAT_VAR = ['--you', '--foe', '--good', '--kw']

/**
 * Battle Royale's board. Deliberately plainer than Board.tsx: no cinematic
 * swing playback, no per-side screen rotation (see the migration header and
 * the project's own priority list -- a playable-if-rough UI beats a
 * half-built one that rotates). Every seat simply sees the board the way the
 * server holds it, seat 0's quadrant at the top-left.
 *
 * It decides nothing either, same as rules.ts/Board.tsx: `reachable` and
 * `targets` are handed down already computed by rulesRoyale.ts, and every
 * click is still checked again by the matching RPC.
 */
export function RoyaleBoard({
  state, mySeat, selected, reachable, targets, watching, onUnitClick, onTileClick, onTreeClick,
}: {
  state: RoyaleMatchState
  mySeat: number | null
  selected: string | null
  reachable: Set<string>
  targets: Map<string, RoyaleTarget>
  watching: boolean
  onUnitClick: (u: RoyaleUnit) => void
  onTileClick: (x: number, y: number) => void
  onTreeClick: (id: string) => void
}) {
  const { w, h } = state.board
  const unitAt = new Map(state.units.map((u) => [rkey(u.x, u.y), u]))
  const treeAt = new Map((state.obstacles ?? []).map((o) => [rkey(o.x, o.y), o]))

  const zoneOf = (x: number, y: number): number | null => {
    for (let s = 0; s < 4; s++) {
      const z = royaleZone(s)
      if (z && x >= z[0] && x <= z[1] && y >= z[2] && y <= z[3]) return s
    }
    return null
  }

  const cells: React.ReactNode[] = []
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const k = rkey(x, y)
      const u = unitAt.get(k)
      const tree = treeAt.get(k)
      const seat = zoneOf(x, y)
      const isMine = u && u.owner === mySeat
      const isSelected = u?.id === selected
      const canMoveHere = !u && !tree && reachable.has(k)
      const target = u ? targets.get(u.id) : tree ? targets.get(tree.id) : undefined
      const classes = ['rtile', `rtile-zone${seat}`]
      if (canMoveHere) classes.push('rtile-move')
      if (target) classes.push(`rtile-target rtile-target-${target.kind}`)
      classes.push(watching ? 'rtile-watch' : '')

      cells.push(
        <div
          key={k}
          className={classes.join(' ')}
          style={{ gridColumn: x + 1, gridRow: y + 1 }}
          onClick={() => {
            if (watching) return
            if (u) { onUnitClick(u); return }
            if (tree && target) { onTreeClick(tree.id); return }
            if (canMoveHere) onTileClick(x, y)
          }}
        >
          {tree && !u && (
            <div className="robj" title={objKind(tree)}>
              {objKind(tree) === 'tree' ? '🌲' : '?'}
              <div className="robj-hp">{tree.hp}</div>
            </div>
          )}
          {u && (
            <div
              className={`runit${isMine ? ' runit-mine' : ''}${isSelected ? ' runit-selected' : ''}`}
              style={{ '--seat': `var(${SEAT_VAR[u.owner] ?? '--muted'})` } as React.CSSProperties}
              title={`${u.name} (${u.hp}/${u.maxHp})`}
            >
              {u.royal && <span className="runit-crown" aria-hidden="true">♛</span>}
              <span className="runit-name">{u.name.slice(0, 3)}</span>
              <span className="runit-hp">{u.hp}</span>
              {u.spent && <span className="runit-spent" aria-hidden="true" />}
            </div>
          )}
        </div>,
      )
    }
  }

  return (
    <div
      className="rboard"
      style={{ gridTemplateColumns: `repeat(${w}, 1fr)`, gridTemplateRows: `repeat(${h}, 1fr)` }}
    >
      {cells}
    </div>
  )
}
