import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'

/**
 * Bot Training Data Center. One button: "Simulate". Under the hood it
 * always does two things in sequence, because they are not the same job --
 * see 0115's own comment for why a single mixed run can't do both. IMPROVE
 * runs first, DATA second, and that order matters:
 *
 *  1. A candidate-vs-live run of AT LEAST 3000 games (a freshly mutated
 *     brain against the current one) that decides, on its own, whether to
 *     replace the live Expert brain -- only if the candidate actually won
 *     more. This one changes real behaviour, so it always runs at the full
 *     3000+ regardless of what was typed in the box, because fewer than
 *     that is too noisy a signal to trust with a live change.
 *  2. A clean self-play run (whichever brain is now live vs. itself) for
 *     however many games the admin asked for. This is what every number
 *     below is built from -- it never changes anything.
 *
 * Jared, catching an earlier draft that gathered data BEFORE the possible
 * promotion: "wouldn't it make more sense to get the data after the
 * training? otherwise would it be outdated?" Exactly right -- if step 1
 * promotes a new brain, stats collected before that would describe a bot
 * that no longer exists by the time the click finishes. Improve-then-data
 * guarantees every number on this screen always describes whichever brain
 * is actually live right now.
 *
 * Jared, after seeing the two-button version: "if I didn't see a need for
 * 2 buttons before, now even less" -- and then, given free rein: "you do
 * whatever you think will be best to make an unbeatable bot, and to get me
 * the specific data I want." This is that: one action, always both jobs in
 * the order that keeps the data honest, no separate confirmation step.
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
// The minimum games the "test an improvement" half of every Simulate click
// always runs, no matter how small a number the admin typed -- see the
// header comment.
const MIN_TEACH_GAMES = 3000

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
interface StatMetricRow { metric: string; value: number }
interface CardValueRow {
  card_slug: string; role: string; royal: boolean; games: number
  win_rate: number; predicted_win_rate: number
  ability_value: number; ability_value_power_equiv: number | null; total_value_power_equiv: number | null
}
interface AbilityValueRow { ability: string; cards_with: number; cards_without: number; avg_ability_value: number }

function pct(n: number | null | undefined): string {
  return n == null ? '--' : `${Math.round(n * 100)}%`
}
function num(n: number | null | undefined, digits = 1): string {
  return n == null ? '--' : n.toFixed(digits)
}
// Signed, finer-grained percentage for numbers that are naturally small (a
// single stat point rarely swings a win rate by whole percentage points).
function pctSigned(n: number | null | undefined, digits = 2): string {
  if (n == null) return '--'
  const v = n * 100
  return `${v >= 0 ? '+' : ''}${v.toFixed(digits)}%`
}
function ptsSigned(n: number | null | undefined, digits = 1): string {
  if (n == null) return '--'
  return `${n >= 0 ? '+' : ''}${n.toFixed(digits)}`
}
const ABILITY_LABEL: Record<string, string> = {
  heals: 'Heals', burns: 'Burns', stuns: 'Stuns', parries: 'Parries', tramples: 'Tramples',
  cures: 'Cures status', poisons_adjacent: 'Poisons nearby', slippery: 'Slippery',
  parry_all: 'Parries everything', blooms: 'Blooms', sneaks: 'Sneaks',
}

export function AdminTraining() {
  const [cardNames, setCardNames] = useState<Record<string, string>>({})
  const [runs, setRuns] = useState<TrainingRun[]>([])
  const [activeRun, setActiveRun] = useState<TrainingRun | null>(null)
  const [lastTrainRun, setLastTrainRun] = useState<TrainingRun | null>(null)
  const [phase, setPhase] = useState<'train' | 'teach' | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [games, setGames] = useState('300')
  const cancelRef = useRef(false)

  const [roleTab, setRoleTab] = useState('all')
  const [scope, setScope] = useState<'all' | 'run'>('all')
  const [perf, setPerf] = useState<CardPerf[] | null>(null)
  const [tiers, setTiers] = useState<TierRow[] | null>(null)
  const [synergy, setSynergy] = useState<SynergyRow[] | null>(null)
  const [bestTeams, setBestTeams] = useState<BestTeam[] | null>(null)
  const [spotChecks, setSpotChecks] = useState<Record<number, { busy: boolean; winRate?: number }>>({})
  const [dashErr, setDashErr] = useState<string | null>(null)

  const [statModel, setStatModel] = useState<StatMetricRow[] | null>(null)
  const [cardValues, setCardValues] = useState<CardValueRow[] | null>(null)
  const [abilityValues, setAbilityValues] = useState<AbilityValueRow[] | null>(null)
  const [valueErr, setValueErr] = useState<string | null>(null)

  const refreshRuns = useCallback(async () => {
    const { data } = await supabase
      .from('training_runs').select('*').order('created_at', { ascending: false }).limit(10)
    if (data) setRuns(data as TrainingRun[])
  }, [])

  // Never scope to a teach run -- its games are half an untested candidate,
  // never a clean read of "what does my roster actually do" (see 0115).
  const runFilter = scope === 'run' && lastTrainRun ? lastTrainRun.id : null

  const refreshDashboards = useCallback(async () => {
    setDashErr(null)
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
  }, [runFilter, roleTab])

  const refreshValues = useCallback(async () => {
    setValueErr(null)
    const [m, c, a] = await Promise.all([
      supabase.rpc('admin_stat_value_model', { p_run: runFilter }),
      supabase.rpc('admin_card_value', { p_run: runFilter }),
      supabase.rpc('admin_ability_value', { p_run: runFilter }),
    ])
    if (m.error || c.error || a.error) {
      setValueErr((m.error ?? c.error ?? a.error)?.message ?? 'failed to load stat values')
      return
    }
    setStatModel(m.data as StatMetricRow[])
    setCardValues(c.data as CardValueRow[])
    setAbilityValues(a.data as AbilityValueRow[])
  }, [runFilter])

  useEffect(() => {
    void refreshRuns()
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
  useEffect(() => { void refreshValues() }, [refreshValues])

  const cardLabel = (slug: string) => cardNames[slug] ?? slug

  async function runPhase(kind: 'train' | 'teach', n: number): Promise<TrainingRun | null> {
    const { data: run, error } = await supabase.rpc('admin_start_training_run', {
      p_kind: kind, p_games: n, p_level: 3,
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
    return cur
  }

  async function runSimulate() {
    const n = Math.max(1, Math.round(Number(games)) || 300)
    setBusy(true); setErr(null); cancelRef.current = false
    try {
      // Improve FIRST, gather data SECOND. If this click promotes a new
      // live brain, the stats below must describe THAT brain, not the one
      // it just replaced -- gathering data before the possible promotion
      // would make every number stale the moment the click finishes.
      setPhase('teach')
      await runPhase('teach', Math.max(n, MIN_TEACH_GAMES))

      if (!cancelRef.current) {
        setPhase('train')
        const trainRun = await runPhase('train', n)
        if (trainRun) setLastTrainRun(trainRun)
      }

      await refreshRuns()
      await refreshDashboards()
      await refreshValues()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false); setPhase(null); setActiveRun(null)
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

  const statByMetric = Object.fromEntries((statModel ?? []).map((r) => [r.metric, r.value]))
  const insufficientN = statByMetric['insufficient_data'] as number | undefined
  const hasModel = statModel != null && insufficientN == null

  return (
    <div className="admin-training">
      <p className="muted tiny">
        One button, two things happen, in this order. Every game is a
        real Expert-level battle, played by the same engine a human's bot
        match uses, against a hidden system account -- never the ladder,
        never a real player. First it always plays at least
        {' '}{MIN_TEACH_GAMES.toLocaleString()} games between the current
        live Expert bot and a freshly tweaked version of it, and if that
        tweak actually wins more, it immediately becomes the new live
        Expert bot for every real player. Then it plays the number of games
        below using whichever bot is now live, purely to fill in the data
        below -- so what you see always describes the bot that's live right
        now, never one that's already been replaced.
      </p>

      <div className="admin-grid admin-nums">
        <label><span>Games to simulate</span>
          <input type="number" min={1} max={20000} value={games}
            onChange={(e) => setGames(e.target.value)} disabled={busy} />
        </label>
        <button
          type="button" className="btn small primary"
          disabled={busy}
          onClick={() => void runSimulate()}
        >
          {busy
            ? (phase === 'teach' ? 'Improving…' : 'Gathering data…')
            : 'Simulate'}
        </button>
      </div>

      {busy && activeRun && (
        <div className="training-progress">
          <div className="training-progress-bar">
            <div className="training-progress-fill" style={{ width: `${progressPct}%` }} />
          </div>
          <p className="muted tiny">
            {phase === 'teach' ? 'Step 1 of 2 -- testing an improvement: ' : 'Step 2 of 2 -- gathering fresh data: '}
            {activeRun.games_completed} / {activeRun.games_requested} games ({progressPct}%)
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
              <td>{r.kind === 'teach' ? 'Improve' : 'Data'}</td>
              <td>{r.games_completed}/{r.games_requested}</td>
              <td>{r.status}</td>
              <td>
                {r.kind === 'teach' && r.summary
                  ? `new version ${r.summary.candidate_wins ?? 0} - old version ${r.summary.baseline_wins ?? 0}` +
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
          disabled={!lastTrainRun} onClick={() => setScope('run')}
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
            <tr><td colSpan={10} className="muted tiny">No simulated games yet -- hit Simulate to gather data.</td></tr>
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

      <hr className="matchend-divider" />

      <h4>What each stat and ability is actually worth</h4>
      <p className="muted tiny">
        Solved from the games above: how much one extra point of Attack, HP,
        Range or Move changes a card's win rate, holding the other three
        fixed. A card's "ability value" is the gap between its real,
        simulated win rate and what its raw stats alone would predict --
        positive means its ability is winning it games beyond its numbers,
        expressed both directly and as "how many attack points that's worth."
      </p>
      {valueErr && <p className="error tiny">{valueErr}</p>}
      {!hasModel && (
        <p className="muted tiny">
          Not enough different cards with real games yet (need at least 8,
          have {insufficientN ?? 0}) -- simulate more games to unlock this.
        </p>
      )}
      {hasModel && (
        <>
          <div className="admin-grid admin-nums">
            <div className="training-stat-tile">
              <span className="muted tiny">1 Attack point</span>
              <strong>{pctSigned(statByMetric['power_point'])}</strong>
            </div>
            <div className="training-stat-tile">
              <span className="muted tiny">1 HP point</span>
              <strong>{pctSigned(statByMetric['hp_point'])}</strong>
            </div>
            <div className="training-stat-tile">
              <span className="muted tiny">1 Range point</span>
              <strong>{pctSigned(statByMetric['range_point'])}</strong>
            </div>
            <div className="training-stat-tile">
              <span className="muted tiny">1 Move point</span>
              <strong>{pctSigned(statByMetric['move_point'])}</strong>
            </div>
          </div>
          <p className="muted tiny">(win rate gained or lost per point, all else held equal)</p>

          <table className="admin-training-table">
            <thead>
              <tr>
                <th>Card</th><th>Games</th><th>Real win %</th><th>Predicted from stats</th>
                <th>Ability value</th><th>~ Attack points</th>
              </tr>
            </thead>
            <tbody>
              {(cardValues ?? []).map((c) => (
                <tr key={c.card_slug}>
                  <td>{cardLabel(c.card_slug)}</td>
                  <td>{c.games}</td>
                  <td>{pct(c.win_rate)}</td>
                  <td>{pct(c.predicted_win_rate)}</td>
                  <td className={c.ability_value > 0 ? 'good' : c.ability_value < 0 ? 'bad' : ''}>
                    {pctSigned(c.ability_value)}
                  </td>
                  <td className={c.ability_value > 0 ? 'good' : c.ability_value < 0 ? 'bad' : ''}>
                    {ptsSigned(c.ability_value_power_equiv)}
                  </td>
                </tr>
              ))}
              {cardValues && cardValues.length === 0 && (
                <tr><td colSpan={6} className="muted tiny">No card values yet.</td></tr>
              )}
            </tbody>
          </table>

          <h4>Value by ability type</h4>
          <p className="muted tiny">
            Only shown once at least two cards have the ability and two
            don't -- a single card either way isn't a comparison.
          </p>
          <table className="admin-training-table">
            <thead><tr><th>Ability</th><th>Cards with it</th><th>Cards without</th><th>Avg. value</th></tr></thead>
            <tbody>
              {(abilityValues ?? []).map((a) => (
                <tr key={a.ability}>
                  <td>{ABILITY_LABEL[a.ability] ?? a.ability}</td>
                  <td>{a.cards_with}</td>
                  <td>{a.cards_without}</td>
                  <td className={a.avg_ability_value > 0 ? 'good' : a.avg_ability_value < 0 ? 'bad' : ''}>
                    {pctSigned(a.avg_ability_value)}
                  </td>
                </tr>
              ))}
              {abilityValues && abilityValues.length === 0 && (
                <tr><td colSpan={4} className="muted tiny">Not enough cards on both sides of any ability yet.</td></tr>
              )}
            </tbody>
          </table>
        </>
      )}
    </div>
  )
}
