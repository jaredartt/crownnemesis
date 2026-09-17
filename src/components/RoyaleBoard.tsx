import { useLayoutEffect, useRef } from 'react'
import { artUrl, faceUrl } from '../lib/art'
import type { RoyaleMatchState, RoyaleUnit } from '../lib/types'
import type { RoyaleTarget } from '../lib/rulesRoyale'
import { rkey, royaleZone } from '../lib/rulesRoyale'
import { objKind } from '../lib/objects'
import { playMove, playPlace } from '../lib/sfx'
import { useT } from '../lib/i18n'

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

/** What the action menu shows for whichever of your own units is selected.
 *  Computed by RoyaleMatch.tsx (the same way Board.tsx computes canMove/
 *  canStrike/canAbility for 1v1) and handed down here purely to render --
 *  this board still decides nothing about whether an action is legal, only
 *  where to draw the menu that offers it. */
export interface RoyaleMenu {
  unit: RoyaleUnit
  canMove: boolean
  canAttack: boolean
  canAbility: boolean
  hasAbility: boolean
  showWait: boolean
  onOpenMove: () => void
  onOpenAttack: () => void
  onAbility: () => void
  onDefend: () => void
  onWait: () => void
  onCancel: () => void
}

/**
 * Battle Royale's board. Meant to look and feel like the same game as 1v1's
 * own `.board`/`.unit`/`.tile`: the same card art (`Portrait`-style crop-
 * with-fallback straight from art.ts), the same rhombus health bar, the
 * same tile corners and container-query sizing, the same lunge/recoil/
 * floating-number hit animation, the same FLIP slide a piece plays when it
 * changes square, and now -- since this pass -- the same anchored action
 * menu (Move/Attack/Ability/Defend/Wait/Cancel) Board.tsx opens on a unit
 * instead of a persistent bottom action bar that never told you what a
 * click would do.
 *
 * Units and trees are siblings of the tiles in the SAME CSS grid, each
 * placed with its own explicit gridColumn/gridRow, exactly the way
 * Board.tsx's drawnUnits/drawnTrees sit beside its tile cells rather than
 * nested inside them. That is what the FLIP slide needs: a unit keyed by
 * its OWN id (`key={u.id}`), not by the tile it happens to occupy, so
 * moving a unit changes one element's grid position instead of unmounting
 * it from one cell and mounting a fresh one in another.
 *
 * Its CSS classes are named `.rbtile`/`.rbunit`/`.rbboard` rather than the
 * shorter `.rtile`/`.runit` this file used to render -- `.rtile` collided
 * with Kingdoms.tsx's roster-picker tile class of the same name, so every
 * royale tile was also picking up that picker's leaning-card skew and
 * hover transform -- a tall rhomboid instead of a square tile.
 *
 * It decides nothing either, same as rules.ts/Board.tsx: `reachable` and
 * `targets` are handed down already computed by rulesRoyale.ts, and every
 * click is still checked again by the matching RPC.
 */
export function RoyaleBoard({
  state, mySeat, selected, reachable, targets, watching, blow, menu,
  onUnitClick, onTileClick, onTreeClick,
}: {
  state: RoyaleMatchState
  mySeat: number | null
  selected: string | null
  reachable: Set<string>
  targets: Map<string, RoyaleTarget>
  watching: boolean
  blow?: RoyaleBlow | null
  /** Present exactly when a menu should be open, over your own selected
   *  unit -- absent during Move/Attack aiming, during deployment, and for
   *  a unit that is not yours. */
  menu?: RoyaleMenu | null
  onUnitClick: (u: RoyaleUnit) => void
  onTileClick: (x: number, y: number) => void
  onTreeClick: (id: string) => void
}) {
  const t = useT()
  const { w, h } = state.board
  const unitAt = new Map(state.units.map((u) => [rkey(u.x, u.y), u]))
  const treeAt = new Map((state.obstacles ?? []).map((o) => [rkey(o.x, o.y), o]))
  const at = (p: { x: number; y: number }) => ({ gridColumn: p.x + 1, gridRow: p.y + 1 }) as React.CSSProperties

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

  // The FLIP slide -- a direct port of Board.tsx's own `seats`/`slots`
  // effect. A card changes square by changing which grid cell it is in,
  // which is instant and unreadable, so this plays the change back: it
  // puts the card's element where it used to be (via a transform, not a
  // DOM move) and lets it travel to zero. What moved is decided from the
  // units' OWN coordinates against the last-seen copy, never from screen
  // rects -- a strip elsewhere on the page growing or shrinking must never
  // make the whole army appear to slide.
  const seats = useRef(new Map<string, { x: number; y: number }>())
  const slots = useRef(new Map<string, HTMLDivElement>())
  const deploying = state.phase === 'deploy'
  useLayoutEffect(() => {
    const live = new Set<string>()
    const moves: { el: HTMLDivElement; dx: number; dy: number }[] = []
    for (const u of state.units) {
      live.add(u.id)
      const was = seats.current.get(u.id)
      seats.current.set(u.id, { x: u.x, y: u.y })
      const el = slots.current.get(u.id)
      if (!el || !was || (was.x === u.x && was.y === u.y)) continue
      // An exchange already owns the CARD's transform; do not fight it. The
      // strike/hurt classes land on the `.rbunit` child, not this wrapper.
      const inner = el.querySelector('.rbunit')
      if (inner && (inner.className.includes('rbunit-strike') || inner.className.includes('rbunit-hurt'))) continue
      const cell = el.getBoundingClientRect()
      const gs = el.parentElement ? getComputedStyle(el.parentElement) : null
      const gapX = parseFloat(gs?.columnGap ?? '0') || 0
      const gapY = parseFloat(gs?.rowGap ?? '0') || 0
      moves.push({
        el,
        dx: (was.x - u.x) * (cell.width + gapX),
        dy: (was.y - u.y) * (cell.height + gapY),
      })
    }
    if (moves.length > 0 && moves.length <= 2) {
      for (const m of moves) {
        m.el.animate(
          [{ transform: `translate(${m.dx}px, ${m.dy}px)` }, { transform: 'translate(0px, 0px)' }],
          { duration: 240, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' },
        )
      }
      ;(deploying ? playPlace : playMove)()
    }
    for (const id of [...seats.current.keys()]) if (!live.has(id)) seats.current.delete(id)
  })

  const tileCells: React.ReactNode[] = []
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const k = rkey(x, y)
      const u = unitAt.get(k)
      const tree = treeAt.get(k)
      const seat = zoneOf(x, y)
      const canMoveHere = !u && !tree && reachable.has(k)
      const classes = ['rbtile', `rbtile-zone${seat}`]
      if (canMoveHere) classes.push('rbtile-move')
      classes.push(watching ? 'rbtile-watch' : '')
      tileCells.push(
        <div
          key={k}
          className={classes.join(' ')}
          style={at({ x, y })}
          onClick={(e) => { e.stopPropagation(); if (!watching) onTileClick(x, y) }}
        />,
      )
    }
  }

  const trees = [...treeAt.values()]
  const units = state.units
  const menuUnit = menu?.unit

  return (
    <div
      className="rbboard"
      style={{ '--cols': w, '--rows': h } as React.CSSProperties}
      onClick={() => { if (menu) menu.onCancel() }}
    >
      <div
        className="rbboard-grid"
        style={{ gridTemplateColumns: `repeat(${w}, 1fr)`, gridTemplateRows: `repeat(${h}, 1fr)` }}
      >
        {tileCells}

        {trees.map((tree) => {
          const target = targets.get(tree.id)
          const id = tree.id
          const isAtk = Boolean(blow && id === blow.atk)
          const hit = blow && id
            ? blow.hits?.find((hh) => hh.id === id)
              ?? (blow.tgt === id ? { id, dmg: blow.dmg, heal: blow.heal } : undefined)
            : undefined
          return (
            <div
              key={tree.id}
              className={`rbtile-obj${target ? ` rbtile-target rbtile-target-${target.kind}` : ''}`}
              style={at(tree)}
              onClick={(e) => {
                e.stopPropagation()
                if (!watching && target) onTreeClick(tree.id)
              }}
            >
              <div className="robj" title={objKind(tree)}>
                {objKind(tree) === 'tree' ? '🌲' : '?'}
                <div className="robj-hp">{tree.hp}</div>
              </div>
              {hit && !hit.heal && (
                <div className={`dmg${isAtk && blow?.crit ? ' dmg-crit' : ''}`}>-{hit.dmg}</div>
              )}
            </div>
          )
        })}

        {units.map((u) => {
          const target = targets.get(u.id)
          const isMine = u.owner === mySeat
          const isSelected = u.id === selected
          const striking = Boolean(blow && u.id === blow.atk)
          const struck = Boolean(blow && u.id === blow.tgt)
          const hit = blow
            ? blow.hits?.find((hh) => hh.id === u.id)
              ?? (blow.tgt === u.id ? { id: u.id, dmg: blow.dmg, heal: blow.heal } : undefined)
            : undefined
          const showCounter = striking && Boolean(blow?.counter)
          return (
            <div
              key={u.id}
              ref={(el) => { if (el) slots.current.set(u.id, el); else slots.current.delete(u.id) }}
              className={`rbunit-slot${target ? ` rbtile-target rbtile-target-${target.kind}` : ''}`}
              style={at(u)}
              onClick={(e) => {
                e.stopPropagation()
                if (watching) return
                onUnitClick(u)
              }}
            >
              <RoyaleUnitCard
                u={u} isMine={isMine} isSelected={isSelected}
                isAtk={striking}
                lean={striking && atkPos && tgtPos ? leanOf(atkPos, tgtPos) : undefined}
                hurt={struck && !blow?.killedTgt && !hit?.heal}
                crit={Boolean(blow?.crit) && struck}
              />
              {hit && (hit.heal
                ? <div className="dmg dmg-heal">+{hit.heal}</div>
                : (
                  <div className={`dmg${blow?.crit && struck ? ' dmg-crit' : ''}`}>
                    -{hit.dmg}
                  </div>
                ))}
              {showCounter && <div className="dmg dmg-late">-{blow!.counter}</div>}
            </div>
          )
        })}

        {/* The action menu. Anchored to the tile the unit is standing on,
            drawn over the board rather than beside it -- a direct port of
            Board.tsx's own `.actmenu`, same CSS, same "opens away from the
            nearest edge" rule so Cancel is never off screen. */}
        {menu && menuUnit && (
          <div className="actmenu-slot" style={at(menuUnit)}>
            <div
              className={[
                'actmenu',
                menuUnit.x > (w - 1) / 2 ? 'is-left' : '',
                menuUnit.y > (h - 1) / 2 ? 'is-up' : '',
              ].join(' ')}
              role="menu"
              aria-label={t('board.chooseAction', { name: menuUnit.name })}
              onClick={(e) => e.stopPropagation()}
            >
              <div className="actmenu-head">{menuUnit.name}</div>
              <button role="menuitem" disabled={!menu.canMove} onClick={menu.onOpenMove}>
                {t('board.move')}
              </button>
              <button role="menuitem" disabled={!menu.canAttack} onClick={menu.onOpenAttack}>
                {t(menuUnit.heals ? 'board.strikeMend' : 'board.attack')}
              </button>
              {menu.hasAbility && (
                <button role="menuitem" disabled={!menu.canAbility} onClick={menu.onAbility}>
                  {t('board.ability')}
                </button>
              )}
              <button role="menuitem" disabled={!menu.canAttack} title={t('board.defendNote')} onClick={menu.onDefend}>
                {t('board.defend')}
              </button>
              {menu.showWait && (
                <button role="menuitem" onClick={menu.onWait}>
                  {t('board.wait')}
                </button>
              )}
              <button role="menuitem" className="actmenu-cancel" onClick={menu.onCancel}>
                {t('board.cancel')}
              </button>
            </div>
          </div>
        )}
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
