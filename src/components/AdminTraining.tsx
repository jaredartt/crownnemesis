import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'

/**
 * Bot Training Data Center -- Phase 1 (see 0114_bot_training_data_center.sql
 * for the full design). "Train" simulates real bot-vs-bot Expert games and
 * shows what happened; it never changes anything the live Expert bot does.
 * "Teach Expert bot" also simulates real games, but this time one side
 * plays a freshly mutated candidate brain against the current live one --
 * and if the candidate actually won more of those games, IT becomes the new
 * live brain the moment the run finishes. Every number on this screen comes
 * straight out of sim_unit_stats / sim_games; nothing here is modelled or
 * guessed, per Jared's own "make sure the obtained data is legit" brief.
 */

type Role = 'royal' | 'knight' | 'rogue' | 'mage' | 'flying'
const ROLE_LABEL: Record<Role, string> = {
  royal: 'Royal', knight: 'Knight', rogue: 'Rogue', mage: 'Mage', flying: 'Flying',
}
const ROLE_TABS: Array<{ key: string; label: string; royalOnly: boolean | null; role: Role | null }> = [
  { key: 'all', label: 'All units', royalOnly: null, role: null },
  { key: 'kings', label: 'Kings', royalOnly: true, role: null },
  { key: 'knight', label: 'Knight', royalOnly: false, role: 'knight' },
  { key: 'rogue', label: 'Rogue', royalOnly: false, role: 'rogue' },
  { key: 'mage', label: 'Mage', royalOnly: false, role: 'mage' },
  { key: 'flying', label: 'Flying', royalOnly: false, role: 'flying' },
]

interface TrainingRun {
  id: string
  kind: 'train' | 'teach'
  level: number
  games_requested: number
  games_completed: number
  status: 'pending' | 'running' | 'completed' | 'failed' | 'cancelled'
  promoted: boolean
  summary: { candidate_wins?: number; baseline_wins?: number; promoted?: boolean } | null
  created_at: string
}

interface CardPerf {
  card_slug: string; role: string; royal: boolean; games: number; win_rate: number
  avg_turns_alive: number; avg_damage_dealt: number; avg_damage_taken: number
  avg_healing_done: number; avg_kills: number; carried_count: number; carry_rate: number
}
interface TierRow {
  card_slug: string; role: string; royal: boolean; games: number; win_rate: number; score: number
}
interface SynergyRow { card_a: string; card_b: string; games: number; win_rate: number; lift: number }
interface BestTeam { deck: string[]; score: number }

function pct(n: number | null | undefined): string {
  return n == null ? '--' : `${Math.round(n * 100)}%`
}
function num(n: number | null | undefined, digits = 1): string {
  return n == null ? '--' : n.toFixed(digits)
}

export function AdminTraining() {
  const [cardNames, setCardNames] = useState<Record<string, string>>({})
  const [runs, setRuns] = useState<TrainingRun[]>([])
  const [activeRun, setActiveRun] = useState<TrainingRun | null>(null)
  const [busy, setBusy] = useState<'train' | 'teach' | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [trainGames, setTrainGames] = useState('100')
  const [teachGames, setTeachGames] = useState('3000')
  const cancelRef = useRef(false)

  const [roleTab, setRoleTab] = useState('all')
  const [scope, setScope] = useState<'all' | 'run'>('all')
  const [perf, setPerf] = useState<CardPerf[] | null>(null)
  const [tiers, setTiers] = useState<TierRow[] | null>(null)
  const [synergy, setSynergy] = useState<SynergyRow[] | null>(null)
  const [bestTeams, setBestTeams] = useState<BestTeam[] | null>(null)
  const [spotChecks, setSpotChecks] = useState<Record<number, { busy: boolean; winRate?: number }>>({})
  const [dashErr, setDashErr] = useState<string | null>(null)

  const refreshRuns = useCallback(async () => {
    const { data } = await supabase
      .from('training_runs').select('*').order('created_at', { ascending: false }).limit(10)
    if (data) setRuns(data as TrainingRun[])
  }, [])

  const refreshDashboards = useCallback(async () => {
    setDashErr(null)
    const runFilter = scope === 'run' && activeRun ? activeRun.id : null
    const tab = ROLE_TABS.find((t) => t.key === roleTab) ?? ROLE_TABS[0]
    const [p, t, s, b] = await Promise.all([
      supabase.rpc('admin_card_performance', { p_run: runFilter }),
      supabase.rpc('admin_tier_list', { p_run: runFilter, p_royal_only: tab.royalOnly, p_role: tab.role }),
      supabase.rpc('admin_pair_synergy', { p_run: runFilter, p_min_games: 10 }),
      supabase.rpc('admin_best_teams', { p_run: runFilter, p_n: 3, p_min_games: 8 }),
    ])
    if (p.error || t.error || s.error || b.error) {
      setDashErr((p.error ?? t.error ?? s.error ?? b.error)?.message ?? 'failed to load dashboards')
      return
    }
    setPerf(p.data as CardPerf[]); setTiers(t.data as TierRow[])
    setSynergy(s.data as SynergyRow[]); setBestTeams(b.data as BestTeam[])
  }, [scope, activeRun, roleTab])

  useEffect(() => {
    void refreshRuns()
    void refreshDashboards()
    supabase.from('cards').select('slug, name').then(({ data }) => {
      if (data) {
        const m: Record<string, string> = {}
        for (const c of data as { slug: string; name: string }[]) m[c.slug] = c.name
        setCardNames(m)
      }
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => { void refreshDashboards() }, [refreshDashboards])

  const cardLabel = (slug: string) => cardNames[slug] ?? slug

  async function startRun(kind: 'train' | 'teach', games: number) {
    setBusy(kind); setErr(null); cancelRef.current = false
    try {
      const { data: run, error } = await supabase.rpc('admin_start_training_run', {
        p_kind: kind, p_games: games, p_level: 3,
      })
      if (error) throw new Error(error.message)
      let cur = run as TrainingRun
      setActiveRun(cur)
      const batch = kind === 'teach' ? 15 : 10
      while (!['completed', 'failed', 'cancelled'].includes(cur.status) && !cancelRef.current) {
        const { data: next, error: e2 } = await supabase.rpc('admin_run_training_batch', {
          p_run: cur.id, p_batch: batch,
        })
        if (e2) throw new Error(e2.message)
        cur = next as TrainingRun
        setActiveRun(cur)
      }
      await refreshRuns()
      await refreshDashboards()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(null)
    }
  }

  async function spotCheck(deck: string[], idx: number) {
    setSpotChecks((s) => ({ ...s, [idx]: { busy: true } }))
    try {
      const { data, error } = await supabase.rpc('admin_spot_check_team', {
        p_deck: deck, p_level: 3, p_games: 30,
      })
      if (error) throw new Error(error.message)
      const row = Array.isArray(data) ? data[0] : data
      setSpotChecks((s) => ({ ...s, [idx]: { busy: false, winRate: row?.win_rate } }))
    } catch (e) {
      setSpotChecks((s) => ({ ...s, [idx]: { busy: false } }))
      setErr((e as Error).message)
    }
  }

  const progressPct = activeRun && activeRun.games_requested > 0
    ? Math.round((activeRun.games_completed / activeRun.games_requested) * 100) : 0

  return (
    <div className="admin-training">
      <p className="muted tiny">
        Every game here is a real Expert-level battle, played out by the same
        engine a human's bot match uses, against a hidden system account --
        never the ladder, never a real player. "Train" only gathers data and
        never changes anything. "Teach Expert bot" also mutates a fresh
        candidate brain and pits it against the current live one; if the
        candidate actually wins more, it becomes the new live Expert brain
        the moment the run finishes.
      </p>

      <div className="admin-grid admin-nums">
        <label><span>Train -- games to simulate</span>
          <input type="number" min={1} max={20000} value={trainGames}
            onChange={(e) => setTrainGames(e.target.value)} disabled={busy !== null} />
        </label>
        <button
          type="button" className="btn small"
          disabled={busy !== null}
          onClick={() => void startRun('train', Math.max(1, Math.round(Number(trainGames)) || 100))}
        >
          {busy === 'train' ? 'Training…' : 'Train'}
        </button>

        <label><span>Teach -- games to simulate</span>
          <input type="number" min={1} max={20000} value={teachGames}
            onChange={(e) => setTeachGames(e.target.value)} disabled={busy !== null} />
        </label>
        <button
          type="button" className="btn small danger"
          disabled={busy !== null}
          onClick={() => {
            if (!window.confirm(
              'This simulates a large batch of games between the current live ' +
              'Expert bot and a freshly mutated candidate. If the candidate wins ' +
              'more, it becomes the new live Expert brain immediately for every ' +
              'real player. Continue?',
            )) return
            void startRun('teach', Math.max(1, Math.round(Number(teachGames)) || 3000))
          }}
        >
          {busy === 'teach' ? 'Teaching…' : 'Teach Expert bot'}
        </button>
      </div>

      {busy && activeRun && (
        <div className="training-progress">
          <div className="training-progress-bar">
            <div className="training-progress-fill" style={{ width: `${progressPct}%` }} />
          </div>
          <p className="muted tiny">
            {activeRun.games_completed} / {activeRun.games_requested} games
            {' '}({progressPct}%) -- {activeRun.kind === 'teach' ? 'candidate vs. live brain' : 'live brain self-play'}
          </p>
          <button type="button" className="btn small ghost" onClick={() => { cancelRef.current = true }}>
            Stop after this batch
          </button>
        </div>
      )}
      {err && <p className="error tiny">{err}</p>}

      <hr className="matchend-divider" />

      <h4>Recent runs</h4>
      <table className="admin-training-table">
        <thead>
          <tr><th>When</th><th>Kind</th><th>Games</th><th>Status</th><th>Result</th></tr>
        </thead>
        <tbody>
          {runs.map((r) => (
            <tr key={r.id}>
              <td>{new Date(r.created_at).toLocaleString()}</td>
              <td>{r.kind === 'teach' ? 'Teach' : 'Train'}</td>
              <td>{r.games_completed}/{r.games_requested}</td>
              <td>{r.status}</td>
              <td>
                {r.kind === 'teach' && r.summary
                  ? `candidate ${r.summary.candidate_wins ?? 0} - baseline ${r.summary.baseline_wins ?? 0}` +
                    (r.promoted ? ' -- PROMOTED to live' : ' -- not promoted')
                  : '--'}
              </td>
            </tr>
          ))}
          {runs.length === 0 && <tr><td colSpan={5} className="muted tiny">No runs yet.</td></tr>}
        </tbody>
      </table>

      <hr className="matchend-divider" />

      <div className="admin-menusubtabs">
        <button type="button" className={`btn small ${scope === 'all' ? 'primary' : 'ghost'}`} onClick={() => setScope('all')}>
          All-time data
        </button>
        <button
          type="button" className={`btn small ${scope === 'run' ? 'primary' : 'ghost'}`}
          disabled={!activeRun} onClick={() => setScope('run')}
        >
          Latest run only
        </button>
      </div>

      <h4>Card performance</h4>
      {dashErr && <p className="error tiny">{dashErr}</p>}
      <table className="admin-training-table">
        <thead>
          <tr>
            <th>Card</th><th>Class</th><th>Games</th><th>Win %</th><th>Avg turns alive</th>
            <th>Avg dmg dealt</th><th>Avg dmg taken</th><th>Avg healing</th><th>Avg kills</th><th>Carry %</th>
          </tr>
        </thead>
        <tbody>
          {(perf ?? []).map((c) => (
            <tr key={c.card_slug}>
              <td>{cardLabel(c.card_slug)}</td>
              <td>{c.royal ? 'Royal' : ROLE_LABEL[c.role as Role] ?? c.role}</td>
              <td>{c.games}</td>
              <td>{pct(c.win_rate)}</td>
              <td>{num(c.avg_turns_alive)}</td>
              <td>{num(c.avg_damage_dealt)}</td>
              <td>{num(c.avg_damage_taken)}</td>
              <td>{num(c.avg_healing_done)}</td>
              <td>{num(c.avg_kills, 2)}</td>
              <td>{pct(c.carry_rate)}</td>
            </tr>
          ))}
          {perf && perf.length === 0 && (
            <tr><td colSpan={10} className="muted tiny">No simulated games yet -- hit Train to gather data.</td></tr>
          )}
        </tbody>
      </table>

      <h4>Tier list</h4>
      <div className="admin-menusubtabs">
        {ROLE_TABS.map((t) => (
          <button
            key={t.key} type="button" className={`btn small ${roleTab === t.key ? 'primary' : 'ghost'}`}
            onClick={() => setRoleTab(t.key)}
          >
            {t.label}
          </button>
        ))}
      </div>
      <table className="admin-training-table">
        <thead><tr><th>Rank</th><th>Card</th><th>Class</th><th>Games</th><th>Win %</th><th>Score</th></tr></thead>
        <tbody>
          {(tiers ?? []).map((c, i) => (
            <tr key={c.card_slug}>
              <td>{i + 1}</td>
              <td>{cardLabel(c.card_slug)}</td>
              <td>{c.royal ? 'Royal' : ROLE_LABEL[c.role as Role] ?? c.role}</td>
              <td>{c.games}</td>
              <td>{pct(c.win_rate)}</td>
              <td>{num(c.score)}</td>
            </tr>
          ))}
          {tiers && tiers.length === 0 && (
            <tr><td colSpan={6} className="muted tiny">Nothing in this class has enough games yet.</td></tr>
          )}
        </tbody>
      </table>

      <h4>Card synergy</h4>
      <p className="muted tiny">
        Two cards' combined win rate against what each scores alone -- a
        positive lift means the pair is genuinely better fought together.
      </p>
      <table className="admin-training-table">
        <thead><tr><th>Pair</th><th>Games together</th><th>Win % together</th><th>Lift</th></tr></thead>
        <tbody>
          {(synergy ?? []).slice(0, 15).map((s) => (
            <tr key={`${s.card_a}|${s.card_b}`}>
              <td>{cardLabel(s.card_a)} + {cardLabel(s.card_b)}</td>
              <td>{s.games}</td>
              <td>{pct(s.win_rate)}</td>
              <td className={s.lift > 0 ? 'good' : s.lift < 0 ? 'bad' : ''}>{s.lift > 0 ? '+' : ''}{pct(s.lift)}</td>
            </tr>
          ))}
          {synergy && synergy.length === 0 && (
            <tr><td colSpan={4} className="muted tiny">Not enough shared games yet to compute synergy.</td></tr>
          )}
        </tbody>
      </table>

      <h4>Best 3 teams the current roster could field</h4>
      <p className="muted tiny">
        Ranked by summed pairwise synergy across the whole roster, not by
        brute-force simulation of every possible team. Spot-check runs 30
        real games for that exact team against random opponents.
      </p>
      <div className="training-teams">
        {(bestTeams ?? []).map((t, i) => (
          <div key={i} className="training-team">
            <strong>#{i + 1}</strong> {t.deck.map(cardLabel).join(', ')}
            <span className="muted tiny"> (synergy score {num(t.score)})</span>
            <button
              type="button" className="btn small ghost"
              disabled={spotChecks[i]?.busy}
              onClick={() => void spotCheck(t.deck, i)}
            >
              {spotChecks[i]?.busy ? 'Checking…' : 'Spot-check (30 games)'}
            </button>
            {spotChecks[i]?.winRate != null && (
              <span className="muted tiny"> -- won {pct(spotChecks[i].winRate)} of 30 vs. random opponents</span>
            )}
          </div>
        ))}
        {bestTeams && bestTeams.length === 0 && (
          <p className="muted tiny">Not enough pair data yet -- simulate more games first.</p>
        )}
      </div>
    </div>
  )
}
