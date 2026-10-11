import { useEffect, useMemo, useState } from 'react'
import { adminCardBalance, type BalanceData, type BalanceRow } from '../lib/api'

/**
 * Admin Mode -> Balance (0218). One row per card, over finished human matches
 * (bot matches and playtests are left out), so you can see what is too strong,
 * too weak, or simply not being played.
 *
 *  - Games / pick rate: how many fielded teams included the card, and the share
 *    of all teams that did.
 *  - Players / players %: distinct people who fielded it, and the share of all
 *    people who played in the period.
 *  - Win rate: wins / (wins + losses); draws count for neither.
 *  - Turns: the average turn number the matches it appeared in reached.
 *  - Damage dealt / taken / healed and survival: ranked matches only, and only
 *    matches played since the per-unit tracker went in (unit_match_stats), so
 *    older matches show a dash.
 */
type Mode = 'all' | 'ranked' | 'casual'
type SortKey = keyof BalanceRow

const COLS: { key: SortKey; label: string; fmt?: (r: BalanceRow) => string; title?: string }[] = [
  { key: 'name', label: 'Card' },
  { key: 'games', label: 'Games', title: 'Teams that fielded it' },
  { key: 'pick_rate', label: 'Pick %', fmt: (r) => pct(r.pick_rate), title: 'Share of all fielded teams that included it' },
  { key: 'players', label: 'Players', title: 'Different people who fielded it' },
  { key: 'player_share', label: 'Players %', fmt: (r) => pct(r.player_share), title: 'Share of all players who used it' },
  { key: 'win_rate', label: 'Win %', fmt: (r) => pct(r.win_rate), title: 'Wins / (wins + losses). Draws count for neither' },
  { key: 'avg_turns', label: 'Avg turns', fmt: (r) => num(r.avg_turns), title: 'Average length of the matches it was in' },
  { key: 'avg_dealt', label: 'Dmg dealt', fmt: (r) => num(r.avg_dealt), title: 'Ranked only: average damage per match' },
  { key: 'avg_taken', label: 'Dmg taken', fmt: (r) => num(r.avg_taken), title: 'Ranked only: average damage taken per match' },
  { key: 'avg_healed', label: 'Healed', fmt: (r) => num(r.avg_healed), title: 'Ranked only: average HP healed per match' },
  { key: 'survival', label: 'Survives', fmt: (r) => pct(r.survival), title: 'Ranked only: share of matches it was still alive at the end' },
]
const pct = (v: number | null) => (v == null ? '—' : `${v}%`)
const num = (v: number | null) => (v == null ? '—' : String(v))

export function AdminBalance() {
  const [mode, setMode] = useState<Mode>('all')
  const [days, setDays] = useState(30)
  const [data, setData] = useState<BalanceData | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>({ key: 'games', dir: -1 })
  const [minGames, setMinGames] = useState(0)

  useEffect(() => {
    let alive = true
    setData(null); setErr(null)
    adminCardBalance(mode, days)
      .then((d) => { if (alive) setData(d) })
      .catch((e) => { if (alive) setErr((e as Error).message) })
    return () => { alive = false }
  }, [mode, days])

  const rows = useMemo(() => {
    const list = (data?.cards ?? []).filter((r) => r.games >= minGames)
    const { key, dir } = sort
    return [...list].sort((a, b) => {
      const x = a[key], y = b[key]
      if (x == null && y == null) return 0
      if (x == null) return 1       // dashes always last
      if (y == null) return -1
      return (typeof x === 'string' ? x.localeCompare(String(y)) : Number(x) - Number(y)) * dir
    })
  }, [data, sort, minGames])

  const click = (key: SortKey) =>
    setSort((s) => (s.key === key ? { key, dir: (-s.dir) as 1 | -1 } : { key, dir: key === 'name' ? 1 : -1 }))

  return (
    <div className="admin-balance">
      <h2>Card balance</h2>
      <div className="bal-filters">
        <div className="seg" role="radiogroup" aria-label="Mode">
          {(['all', 'ranked', 'casual'] as Mode[]).map((m) => (
            <button key={m} type="button" role="radio" aria-checked={mode === m}
                    className={mode === m ? 'is-on' : ''} onClick={() => setMode(m)}>
              {m === 'all' ? 'All matches' : m === 'ranked' ? 'Ranked' : 'Casual'}
            </button>
          ))}
        </div>
        <div className="seg" role="radiogroup" aria-label="Period">
          {([[7, '7 days'], [30, '30 days'], [0, 'All time']] as [number, string][]).map(([d, label]) => (
            <button key={d} type="button" role="radio" aria-checked={days === d}
                    className={days === d ? 'is-on' : ''} onClick={() => setDays(d)}>
              {label}
            </button>
          ))}
        </div>
        <label className="bal-min">
          <span>Min games</span>
          <input type="number" min={0} value={minGames}
                 onChange={(e) => setMinGames(Math.max(0, Math.round(Number(e.target.value)) || 0))} />
        </label>
      </div>

      {err && <p className="error tiny">{err}</p>}
      {!data && !err && <p className="muted">Counting…</p>}
      {data && (
        <>
          <p className="muted tiny">
            {data.totals.teams} fielded teams in this view · {data.totals.tracked_matches} matches have damage
            tracking (ranked, since the tracker went in). Bot matches and playtests are not counted.
          </p>
          <div className="bal-wrap">
            <table className="bal-table">
              <thead>
                <tr>
                  {COLS.map((c) => (
                    <th key={c.key} title={c.title} onClick={() => click(c.key)}
                        className={sort.key === c.key ? 'is-sorted' : ''}>
                      {c.label}{sort.key === c.key ? (sort.dir === 1 ? ' ▲' : ' ▼') : ''}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.slug}>
                    {COLS.map((c) => (
                      <td key={c.key} className={c.key === 'win_rate' ? winClass(r) : ''}>
                        {c.fmt ? c.fmt(r) : String(r[c.key] ?? '')}
                        {c.key === 'name' && r.role && <small className="bal-role"> {r.role}</small>}
                      </td>
                    ))}
                  </tr>
                ))}
                {rows.length === 0 && (
                  <tr><td colSpan={COLS.length} className="muted">No cards match this view yet.</td></tr>
                )}
              </tbody>
            </table>
          </div>
          <p className="muted tiny">
            Win rate is colored once a card has 10+ decided games: green above 55%, red below 45%.
            Damage columns come from ranked matches only, and ability damage is credited to the unit that
            acted; poison and burn count as damage taken only. Small samples lie; do not rebalance on a
            handful of games.
          </p>
        </>
      )}
    </div>
  )
}

function winClass(r: BalanceRow) {
  if (r.win_rate == null || r.wins + r.losses < 10) return ''
  return r.win_rate > 55 ? 'is-hot' : r.win_rate < 45 ? 'is-cold' : ''
}
