import { artUrl, faceUrl } from '../lib/art'
import type { RoyaleMatchState, RoyaleUnit } from '../lib/types'
import type { RoyaleTarget } from '../lib/rulesRoyale'
import { rkey, royaleZone } from '../lib/rulesRoyale'
import { objKind } from '../lib/objects'

const SEAT_VAR = ['--you', '--foe', '--good', '--kw']

/** One exchange, freshly landed -- RoyaleMatch.tsx builds this straight off
 *  `state.fx` (see that file's own comment on why this is inline rather than
 *  1v1's full-screen duel) and hands it down each time `fx.seq` changes. */
export interface RoyaleBlow {
  seq: number
  atk: string
  tgt: string | null
  dmg: number
  heal: number
  crit?: boolean
  counter?: number
  killedTgt?: boolean
  killedAtk?: boolean
  /** An ability's simultaneous receivers (Back to Back and the like) --
   *  present instead of a single `tgt` hit when it applies. */
  hits?: { id: string; dmg?: number; heal?: number }[]
}

/**
 * Battle Royale's board. Still simpler than Board.tsx in one real way -- no
 * full-screen duel cinematic (see RoyaleMatch.tsx's own comment on that) --
 * but everything else here is meant to look and feel like the same game: the
 * same card art (`Portrait`, straight from art.ts, crop-with-fallback and
 * all), the same rhombus health bar, the same tile corners and board sizing
 * as `.board`/`.unit`/`.tile` (1v1), and now the same lunge/recoil/floating-
 * number hit animation too -- reusing 1v1's own `lunge`/`recoil`/`riseaway`
 * keyframes and `.dmg` styling, just triggered inline on the live board
 * instead of inside a paused overlay. No per-side screen rotation either --
 * every seat sees the board the way the server holds it, seat 0's quadrant
 * at the top-left, which is a deliberate, requested property of this board,
 * not a shortcut.
 *
 * Its CSS classes are named `.rbtile`/`.rbunit`/`.rbboard` rather than the
 * shorter `.rtile`/`.runit` this file used to render -- `.rtile` collided
 * with Kingdoms.tsx's roster-picker tile class of the same name (a
 * long-standing, unrelated bug that made every royale tile inherit that
 * picker's leaning-card skew and hover transform, which is why the board
 * looked like a field of tall rhomboids instead of square tiles). Renaming
 * this side of the collision was the smaller, safer fix.
 *
 * It decides nothing either, same as rules.ts/Board.tsx: `reachable` and
 * `targets` are handed down already computed by rulesRoyale.ts, and every
 * click is still checked again by the matching RPC.
 */
export function RoyaleBoard({
  state, mySeat, selected, reachable, targets, watching, blow, onUnitClick, onTileClick, onTreeClick,
}: {
  state: RoyaleMatchState
  mySeat: number | null
  selected: string | null
  reachable: Set<string>
  targets: Map<string, RoyaleTarget>
  watching: boolean
  blow?: RoyaleBlow | null
  onUnitClick: (u: RoyaleUnit) => void
  onTileClick: (x: number, y: number) => void
  onTreeClick: (id: string) => void
}) {
  const { w, h } = state.board
  const unitAt = new Map(state.units.map((u) => [rkey(u.x, u.y), u]))
  const treeAt = new Map((state.obstacles ?? []).map((o) => [rkey(o.x, o.y), o]))

  // Where the attacker and target are standing right now, so the lunge can
  // lean the right way. Only meaningful for an ordinary single-target
  // exchange -- an ability's `hits` array can land on several units at once,
  // which has no one direction to lean toward, so those just flash in place.
  const posOf = new Map<string, { x: number; y: number }>()
  for (const u of state.units) posOf.set(u.id, { x: u.x, y: u.y })
  for (const o of state.obstacles ?? []) posOf.set(o.id, { x: o.x, y: o.y })
  const atkPos = blow ? posOf.get(blow.atk) : undefined
  const tgtPos = blow?.tgt ? posOf.get(blow.tgt) : undefined

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
      const classes = ['rbtile', `rbtile-zone${seat}`]
      if (canMoveHere) classes.push('rbtile-move')
      if (target) classes.push(`rbtile-target rbtile-target-${target.kind}`)
      classes.push(watching ? 'rbtile-watch' : '')

      const id = u?.id ?? tree?.id
      const isAtk = Boolean(blow && id === blow.atk)
      const hit = blow && id
        ? blow.hits?.find((hh) => hh.id === id)
          ?? (blow.tgt === id ? { id, dmg: blow.dmg, heal: blow.heal } : undefined)
        : undefined
      const showCounter = isAtk && Boolean(blow?.counter)

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
            <RoyaleUnitCard
              u={u} isMine={Boolean(isMine)} isSelected={isSelected}
              isAtk={isAtk}
              lean={isAtk && atkPos && tgtPos ? leanOf(atkPos, tgtPos) : undefined}
              hurt={Boolean(hit) && !blow?.killedTgt && !hit?.heal}
              crit={Boolean(blow?.crit) && blow?.tgt === id}
            />
          )}
          {hit && (hit.heal
            ? <div className="dmg dmg-heal">+{hit.heal}</div>
            : (
              <div className={`dmg${blow?.crit && blow.tgt === id ? ' dmg-crit' : ''}`}>
                -{hit.dmg}
              </div>
            ))}
          {showCounter && <div className="dmg dmg-late">-{blow!.counter}</div>}
        </div>,
      )
    }
  }

  return (
    <div
      className="rbboard"
      style={{ '--cols': w, '--rows': h } as React.CSSProperties}
    >
      <div
        className="rbboard-grid"
        style={{ gridTemplateColumns: `repeat(${w}, 1fr)`, gridTemplateRows: `repeat(${h}, 1fr)` }}
      >
        {cells}
      </div>
    </div>
  )
}

/** Which way the attacker's tile should lean -- one grid step's worth of
 *  sign in each axis, same idea as Board.tsx's own lean vector, just read
 *  off real board coordinates instead of a flip-aware duel layout. */
function leanOf(from: { x: number; y: number }, to: { x: number; y: number }) {
  return { x: Math.sign(to.x - from.x) * 16, y: Math.sign(to.y - from.y) * 16 }
}

/** The zoomed crop, falling back to the whole illustration, falling back to
 *  an initial -- the exact same three-step ladder Board.tsx's own Portrait
 *  uses, because it is the same art living at the same path. */
function RoyaleUnitCard({ u, isMine, isSelected, isAtk, lean, hurt, crit }: {
  u: RoyaleUnit
  isMine: boolean
  isSelected: boolean
  isAtk: boolean
  lean?: { x: number; y: number }
  hurt: boolean
  crit: boolean
}) {
  const pct = u.maxHp > 0 ? Math.max(0, Math.round((u.hp / u.maxHp) * 100)) : 0
  const classes = ['rbunit']
  if (isMine) classes.push('rbunit-mine')
  if (isSelected) classes.push('rbunit-selected')
  if (isAtk) classes.push('rbunit-strike')
  if (hurt) classes.push('rbunit-hurt')
  if (crit) classes.push('rbunit-crit')
  return (
    <div
      className={classes.join(' ')}
      style={{
        '--seat': `var(${SEAT_VAR[u.owner] ?? '--muted'})`,
        '--accent': u.accent,
        ...(lean ? { '--lx': `${lean.x}%`, '--ly': `${lean.y}%` } : {}),
      } as React.CSSProperties}
      title={`${u.name} (${u.hp}/${u.maxHp})`}
    >
      <div className="rbunit-face">
        <div className="rbunit-art">
          {u.art
            ? (
              <img
                src={faceUrl(u.art)!}
                alt=""
                onError={(e) => {
                  const el = e.currentTarget
                  const full = artUrl(u.art)
                  if (full && el.src !== full) el.src = full
                }}
              />
            )
            : <span className="rbunit-initial">{u.name[0]}</span>}
        </div>
      </div>
      {u.royal && <span className="rbunit-crown" aria-hidden="true">♛</span>}
      <div className="rbunit-hpbar">
        <div className="rbunit-hpfill" style={{ width: `${pct}%` }} />
        <div className="rbunit-hpnum">{u.hp}</div>
      </div>
      {u.spent && <span className="rbunit-spent" aria-hidden="true" />}
    </div>
  )
}
