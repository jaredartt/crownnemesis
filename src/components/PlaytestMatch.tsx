import { useCallback, useEffect, useMemo, useState } from 'react'
import { Board } from './Board'
import { BattleLog } from './BattleLog'
import { TreeBigCard, UnitBigCard } from './BigCard'
import { GoPips } from './GoPips'
import { supabase } from '../lib/supabase'
import {
  endTurn, ptClear, ptDrop, ptNew, ptObject, ptOwner, ptRemove, ptReset,
  submitAbility, submitAttack, submitDefend, submitMove, submitThrow, submitUndoMove, submitWait,
} from '../lib/api'
import { useCards } from '../lib/useCards'
import { useStructures } from '../lib/useStructures'
import { isSwamped } from '../lib/swamp'
import { artUrl } from '../lib/art'
import { actsCap, type MatchRow, type Side } from '../lib/types'

/**
 * Admin Mode -> Playtest (0213).
 *
 * A sandbox for one person: both teams are yours, any card or structure can be
 * dropped onto the board at any moment, any unit can be handed to the other
 * team at any moment, and nobody ever wins. Nothing about it is online -- no
 * chat, no spectators, no presence, no clock, no opponent to wait for, and no
 * realtime subscription at all (every call hands back the new board).
 *
 * The rules are NOT in this file or anywhere in the client. The room is a real
 * `matches` row; moving, striking, abilities, defending, undoing and passing
 * the turn are the ordinary submit* / end_turn calls, so a playtest follows
 * the 1v1 rules by construction, today and after every future change to them.
 * The Board is the very same component the real match draws. What lives here
 * is only the palette, and each palette action is one pt_* call (0213).
 */

type Team = Side
type Tool =
  | { kind: 'drop'; slug: string }
  | { kind: 'object'; slug: string }
  | { kind: 'erase' }
  | { kind: 'swap' }
  | { kind: 'restore' }

const TEAM_NAME: Record<Team, string> = { guest: 'Blue', host: 'Red' }
const other = (t: Team): Team => (t === 'guest' ? 'host' : 'guest')

/** Rooms this tab has just opened -- lets MatchEntry skip its lookup. */
export const PLAYTEST_IDS = new Set<string>()

export function PlaytestMatch({ matchId, onLeave }: { matchId: string; onLeave: () => void }) {
  const cards = useCards()
  const structures = useStructures()
  const [match, setMatch] = useState<MatchRow | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const [hovered, setHovered] = useState<string | null>(null)
  const [peeked, setPeeked] = useState<string | null>(null)
  const [tool, setTool] = useState<Tool | null>(null)
  const [team, setTeam] = useState<Team>('guest')
  const [query, setQuery] = useState('')
  const [rail, setRail] = useState<'tools' | 'log' | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [watching, setWatching] = useState(false)

  // The room as it stands now. One read; after this every call returns the row.
  useEffect(() => {
    let alive = true
    supabase.from('matches').select('*').eq('id', matchId).maybeSingle()
      .then(({ data }) => { if (alive && data) setMatch(data as MatchRow) })
    return () => { alive = false }
  }, [matchId])

  const run = useCallback(async (fn: () => Promise<unknown>) => {
    setErr(null)
    setBusy(true)
    try {
      const row = (await fn()) as MatchRow | undefined
      if (row && row.state) setMatch(row)
    } catch (e) {
      setErr((e as Error).message)
      setTimeout(() => setErr(null), 3500)
    } finally {
      setBusy(false)
    }
  }, [])

  // Esc puts the palette tool down.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setTool(null) }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // Whoever is to move, or whoever owes the open throw decision -- exactly the
  // side the server's side_of() resolves this account to.
  const s = match?.state
  const acting: Side = (s?.pending?.side ?? s?.turn ?? 'guest') as Side

  const useTool = useCallback((x: number, y: number, hit: string | null) => {
    if (!tool || !s || busy) return
    const id = matchId
    if (tool.kind === 'drop') void run(() => ptDrop(id, tool.slug, team, x, y))
    else if (tool.kind === 'object') {
      void run(() => ptObject(id, tool.slug, tool.slug === 'tree' ? null : team, x, y))
    } else if (!hit) return
    else if (tool.kind === 'erase') void run(() => ptRemove(id, hit))
    else {
      const u = s.units.find((q) => q.id === hit)
      if (!u) return
      if (tool.kind === 'swap') void run(() => ptOwner(id, hit, other(u.owner as Team)))
      else void run(() => ptReset(id, hit))
    }
  }, [tool, s, busy, matchId, team, run])

  const shownCards = useMemo(() => {
    const q = query.trim().toLowerCase()
    return [...cards]
      .filter((c) => !q || c.name.toLowerCase().includes(q) || c.slug.includes(q) || c.role.includes(q))
      .sort((a, b) => a.name.localeCompare(b.name))
  }, [cards, query])

  if (!match || !s) {
    return (
      <div className="center-stage"><p className="muted">Opening the playtest…</p></div>
    )
  }

  const unitAt = (id: string | null) => (id ? s.units.find((u) => u.id === id) : undefined)
  const treeAt = (id: string | null) => (id ? (s.obstacles ?? []).find((o) => o.id === id) : undefined)
  const pinnedUnit = unitAt(selected)
  const pinnedCard = pinnedUnit
    ? <UnitBigCard unit={pinnedUnit} side="left" pinned swamped={isSwamped(s, pinnedUnit)} /> : null
  const hoverId = hovered && hovered !== selected ? hovered : null
  const hoverUnit = unitAt(hoverId)
  const hoverTree = treeAt(hoverId)
  const hoverCard = hoverUnit
    ? <UnitBigCard unit={hoverUnit} side="right" swamped={isSwamped(s, hoverUnit)} />
    : hoverTree ? <TreeBigCard tree={hoverTree} side="right" /> : null
  const peekUnit = unitAt(peeked)
  const peekTree = treeAt(peeked)
  const peekCard = peekUnit
    ? <UnitBigCard unit={peekUnit} side="peek" swamped={isSwamped(s, peekUnit)} />
    : peekTree ? <TreeBigCard tree={peekTree} side="peek" /> : null

  const capNow = actsCap(s)
  const spent = Math.min(capNow, s.acts ?? 0)
  const sel = pinnedUnit
  const isTool = (t: Tool) =>
    tool?.kind === t.kind && (!('slug' in t) || !('slug' in tool) || tool.slug === t.slug)
  const toggle = (t: Tool) => setTool(isTool(t) ? null : t)

  return (
    <div className="match pt-match">
      <header className="matchbar">
        <button className="linkbtn" onClick={onLeave}>← Admin</button>
        <div className="scoreline">
          <span className="pt-title">Playtest</span>
          <span className="pt-sub">your sandbox · nobody wins · nothing is saved to anyone's record</span>
        </div>
        <div className="matchbar-right">
          <button
            className="btn tiny ghost" disabled={busy}
            title="A fresh board: no units, and a new random set of trees"
            onClick={() => { setSelected(null); setTool(null); void run(() => ptNew()) }}
          >
            New board
          </button>
        </div>
      </header>

      <div className="turnbar pt-turnbar">
        <div className="pt-turn" role="group" aria-label="Whose turn it is">
          {(['guest', 'host'] as Team[]).map((t) => (
            <button
              key={t} type="button" disabled={busy}
              className={`pt-turnbtn is-${t}${s.turn === t ? ' is-on' : ''}`}
              title={s.turn === t ? `${TEAM_NAME[t]} to act` : `Pass the turn to ${TEAM_NAME[t]}`}
              onClick={() => { if (s.turn !== t) void run(() => endTurn(matchId)) }}
            >
              {TEAM_NAME[t]}{s.turn === t ? ' · your move' : ''}
            </button>
          ))}
          <span className="pt-turnno">Turn {s.turnNumber}</span>
        </div>
      </div>

      <div className="stage">
        <aside className={`side side-left pt-side${rail === 'tools' ? ' is-open' : ''}`}>
          <h2 className="side-title">Playtest tools</h2>
          <div className="side-body pt-panel">
            <div className="pt-row">
              <span className="pt-label">Drop for</span>
              <div className="pt-seg">
                {(['guest', 'host'] as Team[]).map((t) => (
                  <button
                    key={t} type="button" className={`is-${t}${team === t ? ' is-on' : ''}`}
                    onClick={() => setTeam(t)}
                  >
                    {TEAM_NAME[t]}
                  </button>
                ))}
              </div>
            </div>

            <div className="pt-row pt-tools">
              <button type="button" className={isTool({ kind: 'erase' }) ? 'is-on' : ''}
                      onClick={() => toggle({ kind: 'erase' })} title="Click a unit or structure to take it off">
                Remove
              </button>
              <button type="button" className={isTool({ kind: 'swap' }) ? 'is-on' : ''}
                      onClick={() => toggle({ kind: 'swap' })} title="Click a unit to hand it to the other team">
                Switch team
              </button>
              <button type="button" className={isTool({ kind: 'restore' }) ? 'is-on' : ''}
                      onClick={() => toggle({ kind: 'restore' })}
                      title="Click a unit: full health, no afflictions, a fresh go and a fresh ability">
                Restore
              </button>
            </div>

            <div className="pt-row pt-tools">
              {structures.map((st) => (
                <button
                  key={st.slug} type="button"
                  className={isTool({ kind: 'object', slug: st.slug }) ? 'is-on' : ''}
                  onClick={() => toggle({ kind: 'object', slug: st.slug })}
                  title={`Place ${st.name}`}
                >
                  + {st.name}
                </button>
              ))}
            </div>

            <div className="pt-row pt-tools">
              <button type="button" disabled={busy} onClick={() => void run(() => ptClear(matchId, 'trees'))}
                      title="Re-roll the trees (never onto a unit)">New trees</button>
              <button type="button" disabled={busy} onClick={() => { setSelected(null); void run(() => ptClear(matchId, 'units')) }}>
                Clear units
              </button>
              <button type="button" disabled={busy} onClick={() => { setSelected(null); void run(() => ptClear(matchId, 'all')) }}>
                Clear all
              </button>
            </div>

            {sel && (
              <div className="pt-selected">
                <b>{sel.name}</b>
                <span className={`pt-chip is-${sel.owner}`}>{TEAM_NAME[sel.owner as Team]}</span>
                <div className="pt-row">
                  <button type="button" disabled={busy}
                          onClick={() => void run(() => ptOwner(matchId, sel.id, other(sel.owner as Team)))}>
                    → {TEAM_NAME[other(sel.owner as Team)]}
                  </button>
                  <button type="button" disabled={busy} onClick={() => void run(() => ptReset(matchId, sel.id))}>
                    Restore
                  </button>
                  <button type="button" disabled={busy}
                          onClick={() => { setSelected(null); void run(() => ptRemove(matchId, sel.id)) }}>
                    Remove
                  </button>
                </div>
              </div>
            )}

            <input
              className="pt-search" type="search" placeholder="Search cards…"
              value={query} onChange={(e) => setQuery(e.target.value)}
            />
            <div className="pt-cards">
              {shownCards.map((c) => (
                <button
                  key={c.slug} type="button"
                  className={`pt-card role-${c.role}${isTool({ kind: 'drop', slug: c.slug }) ? ' is-on' : ''}`}
                  onClick={() => toggle({ kind: 'drop', slug: c.slug })}
                  title={`Drop ${c.name} for ${TEAM_NAME[team]}`}
                >
                  {artUrl(c.art_url) && <img src={artUrl(c.art_url)!} alt="" loading="lazy" />}
                  <span>{c.name}</span>
                </button>
              ))}
              {shownCards.length === 0 && <p className="muted tiny">No card matches.</p>}
            </div>
          </div>
        </aside>

        <main className="center">
          <div className="arena" style={{ '--cols': s.board.w, '--rows': s.board.h } as React.CSSProperties}>
            {pinnedCard}
            {hoverCard}
            {peekCard && <div className="peekscrim" onPointerDown={() => setPeeked(null)} aria-hidden="true" />}
            {peekCard}
            <Board
              state={s}
              matchId={matchId}
              mySide={acting}
              isMyTurn
              deploying={false}
              playtest
              tool={tool ? useTool : null}
              selectedId={selected}
              onSelect={setSelected}
              onMove={(x, y) => selected && run(() => submitMove(matchId, selected, x, y))}
              onAttack={(target) => selected && run(() => submitAttack(matchId, selected, target))}
              onAbility={(unitId, target) => run(() => submitAbility(matchId, unitId, target))}
              onThrow={(target) => run(() => submitThrow(matchId, target))}
              onDefend={(targetId) => selected && run(() => submitDefend(matchId, selected, targetId))}
              onWait={() => run(() => submitWait(matchId))}
              onUndoMove={() => run(() => submitUndoMove(matchId))}
              onDeploy={() => {}}
              onHover={setHovered}
              onPeek={setPeeked}
              onWatching={setWatching}
              locked={busy}
            />
          </div>

          <div className="below">
            <div className="unitbar is-goes">
              <GoPips cap={capNow} spent={spent} theirs={false} urgent={false} />
            </div>
            <div className="actionbar">
              <button className="btn primary" disabled={busy || watching}
                      onClick={() => void run(() => endTurn(matchId))}>
                Pass turn to {TEAM_NAME[other(s.turn as Team)]}
              </button>
              <span className="hint">
                {tool
                  ? 'Tool armed: click the board to use it · Esc to put it down'
                  : `${TEAM_NAME[acting]} to act · pick a unit, then its menu`}
              </span>
            </div>
          </div>
          {err && <div className="toast">{err}</div>}
        </main>

        <BattleLog log={s.log} open={rail === 'log'} units={s.units} mineOwner="guest" />

        <nav className="railtabs" role="tablist" aria-label="Side panels">
          <button role="tab" aria-selected={rail === 'tools'} onClick={() => setRail((r) => (r === 'tools' ? null : 'tools'))}>
            Tools
          </button>
          <button role="tab" aria-selected={rail === 'log'} onClick={() => setRail((r) => (r === 'log' ? null : 'log'))}>
            Log
          </button>
        </nav>
      </div>
    </div>
  )
}
