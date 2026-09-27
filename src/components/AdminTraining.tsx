import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'

/**
 * Bot Training Data Center -- rebuilt to Jared's exact, final spec:
 *
 *   "* Button called 'Simulate matches'
 *    * Next to it, field for a number of matches THAT I DECIDE, between
 *      current bot vs mutated.
 *    * A lot of data is shown underneath, the data I asked for above.
 *      Using a lot of animations for the stats, everything super clean,
 *      with space, clear, and with the colors I used all across the UI
 *      of the Game, the vibrant ones.
 *    * Another button called 'Train', which will train the current Expert
 *      bot, and will update its skills to be used anywhere in Crown
 *      Nemesis, in real-time.
 *    * Make everything look clean, spaced out, minimalist, with
 *      animations that will make it easier to understand for admins or
 *      players."
 *
 * Two buttons, nothing else controlling them:
 *  - Simulate matches: candidate (freshly mutated) vs the current live
 *    bot, for however many games Jared types in. Never promotes -- it's a
 *    preview (0117's 'preview' training-run kind). Every number in the
 *    results panel below comes from THIS run's own id, passed explicitly
 *    to every dashboard/value function (admin_card_performance,
 *    admin_stat_value_model, admin_card_value, admin_ability_value).
 *  - Train: applies what Simulate already found (0118's
 *    admin_apply_training_run). No new mutation, no new games -- it reads
 *    the last completed Simulate run's own candidate_wins/baseline_wins
 *    and, if the candidate actually won more, promotes it live right
 *    then. Per Jared: "Simulate obtains the data. Train applies the data
 *    obtained from Simulate."
 *
 * No large explanatory paragraphs anywhere in this file's JSX -- per
 * Jared: "Forget the stupidly huge paragraph you added in this section
 * above everything." Labels, colour and animation carry the meaning
 * instead (see the big comment block in styles.css above .training2).
 */

const DEFAULT_SIM_GAMES = 500

type RunKind = 'train' | 'teach' | 'preview'
type RunStatus = 'pending' | 'running' | 'completed' | 'failed' | 'cancelled'

interface TrainingRun {
  id: string
  kind: RunKind
  level: number
  games_requested: number
  games_completed: number
  status: RunStatus
  promoted: boolean
  summary: {
    candidate_wins?: number; baseline_wins?: number; promoted?: boolean; applied?: boolean
    // 0124: a draw (a real stalemate) and an unresolved game (capped/cut
    // off before either side won) both used to just vanish from these
    // numbers -- games_completed could be bigger than
    // candidate_wins+baseline_wins with no way to see why.
    draws?: number; unresolved?: number
  } | null
  created_at: string
}

interface CardValueRow {
  card_slug: string; role: string; royal: boolean; games: number
  win_rate: number; predicted_win_rate: number
  ability_value: number; ability_value_power_equiv: number | null; total_value_power_equiv: number | null
}
interface AbilityValueRow { ability: string; cards_with: number; cards_without: number; avg_ability_value: number }
interface StatMetricRow { metric: string; value: number }

const ABILITY_LABEL: Record<string, string> = {
  heals: 'Heals', burns: 'Burns', stuns: 'Stuns', parries: 'Parries', tramples: 'Tramples',
  cures: 'Cures status', poisons_adjacent: 'Poisons nearby', slippery: 'Slippery',
  parry_all: 'Parries everything', blooms: 'Blooms', sneaks: 'Sneaks',
}

// The same five role hues painted everywhere else on the board
// (.bigcard/.unit/.rtile.role-*) -- royal overrides role the same way
// admin_card_performance/admin_card_value report it (a separate `royal`
// flag alongside `role`).
function roleClass(role: string, royal: boolean): string {
  if (royal) return 'role-royal'
  return `role-${role}`
}

function pct(n: number | null | undefined, digits = 0): string {
  return n == null ? '--' : `${(n * 100).toFixed(digits)}%`
}
function pctSigned(n: number | null | undefined, digits = 2): string {
  if (n == null) return '--'
  const v = n * 100
  return `${v >= 0 ? '+' : ''}${v.toFixed(digits)}%`
}
function clampGames(raw: string): number {
  const n = Math.round(Number(raw))
  if (!Number.isFinite(n)) return DEFAULT_SIM_GAMES
  return Math.min(20000, Math.max(1, n))
}

// Animates a displayed integer from its previous value up (or down) to a
// new target whenever the target changes -- the "a lot of animations for
// the stats" count-up effect, done once here rather than per-number.
function useCountUp(target: number, ms = 700): number {
  const [shown, setShown] = useState(target)
  const fromRef = useRef(target)
  useEffect(() => {
    const from = fromRef.current
    if (from === target) return
    let raf = 0
    const start = performance.now()
    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / ms)
      const eased = 1 - Math.pow(1 - t, 3)
      setShown(Math.round(from + (target - from) * eased))
      if (t < 1) raf = requestAnimationFrame(tick)
      else fromRef.current = target
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target])
  return shown
}

function CountUpNum({ value, className }: { value: number; className?: string }) {
  const shown = useCountUp(value)
  return <span className={className}>{shown.toLocaleString()}</span>
}

// Always sweeps in from 0 -- unlike useCountUp (which only animates a
// CHANGE from a previous value), this is for the one-shot "reveal" moment
// on the win-rate donut: every fresh Simulate run should watch that ring
// fill up from empty, not just appear at its final angle.
function useAnimateIn(target: number, ms = 900): number {
  const [shown, setShown] = useState(0)
  useEffect(() => {
    let raf = 0
    const start = performance.now()
    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / ms)
      const eased = 1 - Math.pow(1 - t, 3)
      setShown(target * eased)
      if (t < 1) raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target])
  return shown
}

const DONUT_R = 46
const DONUT_C = 2 * Math.PI * DONUT_R

export function AdminTraining() {
  const [cardNames, setCardNames] = useState<Record<string, string>>({})
  const [games, setGames] = useState(String(DEFAULT_SIM_GAMES))
  const [busyKind, setBusyKind] = useState<'simulate' | 'train' | null>(null)
  const [activeRun, setActiveRun] = useState<TrainingRun | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const cancelRef = useRef(false)

  const [simRun, setSimRun] = useState<TrainingRun | null>(null)
  const [trainBanner, setTrainBanner] = useState<TrainingRun | null>(null)

  const [statModel, setStatModel] = useState<StatMetricRow[] | null>(null)
  const [cardValues, setCardValues] = useState<CardValueRow[] | null>(null)
  const [abilityValues, setAbilityValues] = useState<AbilityValueRow[] | null>(null)
  const [barsIn, setBarsIn] = useState(false)

  const cardLabel = useCallback((slug: string) => cardNames[slug] ?? slug, [cardNames])

  // Pick up where the last session left off: the latest completed Simulate
  // (preview) run's data, and the latest Train (teach) run's outcome for
  // the banner -- so reopening the tab doesn't lose either.
  useEffect(() => {
    supabase.from('cards').select('slug, name').then(({ data }) => {
      if (data) {
        const m: Record<string, string> = {}
        for (const c of data as { slug: string; name: string }[]) m[c.slug] = c.name
        setCardNames(m)
      }
    })
    supabase.from('training_runs').select('*')
      .eq('kind', 'preview').eq('status', 'completed')
      .order('created_at', { ascending: false }).limit(1)
      .then(({ data }) => {
        const run = (data as TrainingRun[] | null)?.[0]
        if (run) { setSimRun(run); void loadValues(run.id) }
      })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function loadValues(runId: string) {
    setBarsIn(false)
    const [m, c, a] = await Promise.all([
      supabase.rpc('admin_stat_value_model', { p_run: runId }),
      supabase.rpc('admin_card_value', { p_run: runId }),
      supabase.rpc('admin_ability_value', { p_run: runId }),
    ])
    setStatModel((m.data as StatMetricRow[]) ?? null)
    setCardValues((c.data as CardValueRow[]) ?? null)
    setAbilityValues((a.data as AbilityValueRow[]) ?? null)
    // Bars start at 0 width and animate to their real width on the next
    // frame, so the CSS width-transition actually has something to
    // transition from every time (a fresh run, not just fresh numbers).
    requestAnimationFrame(() => requestAnimationFrame(() => setBarsIn(true)))
  }

  async function runOp(n: number): Promise<TrainingRun> {
    const { data: run, error } = await supabase.rpc('admin_start_training_run', {
      p_kind: 'preview', p_games: n, p_level: 3,
    })
    if (error) throw new Error(error.message)
    let cur = run as TrainingRun
    setActiveRun(cur)
    // 0123: the actual batch-driving loop now runs server-side, in a
    // Supabase Edge Function (train-driver) -- no PostgREST 8s
    // statement_timeout, no need to keep this tab open for a long run, and
    // the service-role key it needs never touches the browser. Each
    // invocation below drives as many games as it can in its own time
    // budget and returns; this just keeps re-invoking (and keeps the
    // progress bar live) until the run is done.
    while (!['completed', 'failed', 'cancelled'].includes(cur.status) && !cancelRef.current) {
      const { data: next, error: e2 } = await supabase.functions.invoke('train-driver', {
        // A smaller wall budget than the function's own 20s default -- so
        // the progress bar actually gets to move instead of sitting still
        // for a whole 20s between updates. Still far fewer round trips
        // than the old 3s-per-batch direct RPC loop.
        body: { run_id: cur.id, wall_budget_ms: 4000 },
      })
      if (e2) throw new Error(e2.message)
      const result = next as { run: TrainingRun | null; error?: string }
      if (!result.run) throw new Error(result.error ?? 'train-driver returned no run')
      cur = result.run
      setActiveRun(cur)
    }
    return cur
  }

  async function onSimulate() {
    const n = clampGames(games)
    setBusyKind('simulate'); setErr(null); setTrainBanner(null); cancelRef.current = false
    try {
      const run = await runOp(n)
      setSimRun(run)
      await loadValues(run.id)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusyKind(null); setActiveRun(null)
    }
  }

  async function onTrain() {
    if (!simRun || simRun.status !== 'completed') return
    setBusyKind('train'); setErr(null)
    try {
      const { data, error } = await supabase.rpc('admin_apply_training_run', { p_run: simRun.id })
      if (error) throw new Error(error.message)
      const applied = data as TrainingRun
      setTrainBanner(applied)
      setSimRun(applied)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusyKind(null)
    }
  }

  const progressPct = activeRun && activeRun.games_requested > 0
    ? Math.round((activeRun.games_completed / activeRun.games_requested) * 100) : 0

  const statByMetric = Object.fromEntries((statModel ?? []).map((r) => [r.metric, r.value]))
  const insufficientN = statByMetric['insufficient_data'] as number | undefined
  const hasModel = statModel != null && insufficientN == null

  const summary = simRun?.summary
  const candWins = summary?.candidate_wins ?? 0
  const baseWins = summary?.baseline_wins ?? 0
  const draws = summary?.draws ?? 0
  const unresolved = summary?.unresolved ?? 0
  const totalWB = candWins + baseWins
  const basePct = totalWB > 0 ? baseWins / totalWB : 0.5
  const candPct = totalWB > 0 ? candWins / totalWB : 0.5
  const candPctAnim = useAnimateIn(candPct, 1100)

  // Rank + spotlight for the Card value list -- computed off the same
  // cardValues the list already renders, just sorted by overall value
  // instead of the list's own (win-rate) order, so the #1/#2/#3 badges and
  // the best/weakest callout are correct no matter how the rows are laid
  // out below.
  const rankedCards = [...(cardValues ?? [])].sort(
    (a, b) => (b.total_value_power_equiv ?? b.ability_value) - (a.total_value_power_equiv ?? a.ability_value)
  )
  const cardRank = new Map(rankedCards.map((c, i) => [c.card_slug, i + 1]))
  const bestCard = rankedCards[0]
  const worstCard = rankedCards.length > 1 ? rankedCards[rankedCards.length - 1] : undefined

  return (
    <div className="training2">
      <div className="training2-actions">
        <div className="training2-action training2-action--sim">
          <div className="training2-action-head">
            <span className="training2-action-label">Simulate matches</span>
            <span className="training2-action-sub">Current bot vs. a mutated challenger</span>
          </div>
          <div className="training2-action-controls">
            <input
              className="training2-games-input" type="number" min={1} max={20000}
              value={games} onChange={(e) => setGames(e.target.value)}
              disabled={busyKind != null}
            />
            <button
              type="button" className="training2-btn"
              disabled={busyKind != null} onClick={() => void onSimulate()}
            >
              {busyKind === 'simulate' ? 'Simulating…' : 'Simulate matches'}
            </button>
          </div>
        </div>

        <div className="training2-action training2-action--train">
          <div className="training2-action-head">
            <span className="training2-action-label">Train</span>
            <span className="training2-action-sub">Promotes your last Simulate challenger live if it won</span>
          </div>
          <button
            type="button" className="training2-btn"
            disabled={busyKind != null || !simRun || simRun.status !== 'completed' || simRun.summary?.applied === true}
            onClick={() => void onTrain()}
          >
            {busyKind === 'train' ? 'Training…' : simRun?.summary?.applied ? 'Applied' : 'Train'}
          </button>
        </div>
      </div>

      {busyKind && activeRun && (
        <div className="training2-progress">
          <div className="training2-progress-track">
            <div className="training2-progress-fill" style={{ width: `${progressPct}%` }} />
          </div>
          <span className="training2-progress-label">
            {activeRun.games_completed.toLocaleString()} / {activeRun.games_requested.toLocaleString()} games
          </span>
          <button type="button" className="training2-stop" onClick={() => { cancelRef.current = true }}>
            Stop
          </button>
        </div>
      )}

      {err && <p className="training2-err">{err}</p>}

      {trainBanner && !busyKind && (
        <div className={`training2-banner ${trainBanner.promoted ? 'is-promoted' : 'is-kept'}`}>
          <span className="training2-banner-dot" />
          <span>
            <strong>Applied.</strong>{' '}
            The challenger {trainBanner.promoted ? 'won' : 'lost'}{' '}
            {trainBanner.summary?.candidate_wins ?? 0} - {trainBanner.summary?.baseline_wins ?? 0}
            {trainBanner.promoted ? ' and is now live.' : ' -- the current bot stays live.'}
          </span>
        </div>
      )}

      {simRun && (
        <div className="training2-results" key={simRun.id}>
          <div className="training2-vs">
            <div className="training2-vs-side training2-vs-side--base">
              <span className="training2-vs-name">Current bot</span>
              <CountUpNum className="training2-vs-num" value={baseWins} />
              <span className="training2-vs-pct">{pct(basePct)}</span>
            </div>
            <div className="training2-vs-mid">
              <svg className="training2-donut" viewBox="0 0 120 120" width="112" height="112">
                <circle className="training2-donut-track" cx="60" cy="60" r={DONUT_R} />
                <circle
                  className="training2-donut-arc" cx="60" cy="60" r={DONUT_R}
                  strokeDasharray={DONUT_C} strokeDashoffset={DONUT_C * (1 - candPctAnim)}
                />
                <text x="60" y="57" textAnchor="middle" className="training2-donut-num">{Math.round(candPctAnim * 100)}%</text>
                <text x="60" y="75" textAnchor="middle" className="training2-donut-sub">challenger</text>
              </svg>
              <span className="training2-vs-games">{simRun.games_completed.toLocaleString()} games simulated</span>
              {(draws > 0 || unresolved > 0) && (
                <span className="training2-vs-extra">
                  {draws > 0 && `${draws.toLocaleString()} draw${draws === 1 ? '' : 's'}`}
                  {draws > 0 && unresolved > 0 && ' · '}
                  {unresolved > 0 && `${unresolved.toLocaleString()} undecided`}
                </span>
              )}
            </div>
            <div className="training2-vs-side training2-vs-side--cand">
              <span className="training2-vs-name">Mutated challenger</span>
              <CountUpNum className="training2-vs-num" value={candWins} />
              <span className="training2-vs-pct">{pct(candPct)}</span>
            </div>
          </div>

          {!hasModel && (
            <p className="training2-empty">
              Not enough different cards with games yet (need at least 8, have {insufficientN ?? 0}) --
              simulate more matches to unlock card and ability values.
            </p>
          )}

          {hasModel && (
            <>
              <div className="training2-tiles">
                <div className="training2-tile training2-tile--power">
                  <span className="training2-tile-label">1 Attack point</span>
                  <span className={`training2-tile-value ${(statByMetric['power_point'] ?? 0) >= 0 ? 'is-good' : 'is-bad'}`}>
                    {pctSigned(statByMetric['power_point'])}
                  </span>
                  <span className="training2-tile-note">win rate per point</span>
                </div>
                <div className="training2-tile training2-tile--hp">
                  <span className="training2-tile-label">1 HP point</span>
                  <span className={`training2-tile-value ${(statByMetric['hp_point'] ?? 0) >= 0 ? 'is-good' : 'is-bad'}`}>
                    {pctSigned(statByMetric['hp_point'])}
                  </span>
                  <span className="training2-tile-note">win rate per point</span>
                </div>
                <div className="training2-tile training2-tile--range">
                  <span className="training2-tile-label">1 Range point</span>
                  <span className={`training2-tile-value ${(statByMetric['range_point'] ?? 0) >= 0 ? 'is-good' : 'is-bad'}`}>
                    {pctSigned(statByMetric['range_point'])}
                  </span>
                  <span className="training2-tile-note">win rate per point</span>
                </div>
                <div className="training2-tile training2-tile--move">
                  <span className="training2-tile-label">1 Move point</span>
                  <span className={`training2-tile-value ${(statByMetric['move_point'] ?? 0) >= 0 ? 'is-good' : 'is-bad'}`}>
                    {pctSigned(statByMetric['move_point'])}
                  </span>
                  <span className="training2-tile-note">win rate per point</span>
                </div>
              </div>

              <div>
                <h4 className="training2-section-title">Card value</h4>
                {bestCard && worstCard && (
                  <div className="training2-mvp">
                    <div className="training2-mvp-card is-best">
                      <span className="training2-mvp-tag">Best card</span>
                      <span className={`training2-mvp-dot ${roleClass(bestCard.role, bestCard.royal)}`} />
                      <span className="training2-mvp-name">{cardLabel(bestCard.card_slug)}</span>
                      <span className="training2-mvp-value">{pctSigned(bestCard.ability_value, 1)}</span>
                    </div>
                    <div className="training2-mvp-card is-worst">
                      <span className="training2-mvp-tag">Weakest card</span>
                      <span className={`training2-mvp-dot ${roleClass(worstCard.role, worstCard.royal)}`} />
                      <span className="training2-mvp-name">{cardLabel(worstCard.card_slug)}</span>
                      <span className="training2-mvp-value">{pctSigned(worstCard.ability_value, 1)}</span>
                    </div>
                  </div>
                )}
                <div className="training2-cards">
                  {(cardValues ?? []).map((c, idx) => {
                    const rank = cardRank.get(c.card_slug) ?? 99
                    return (
                    <div
                      key={c.card_slug}
                      className={`training2-card-row training2-row-anim ${roleClass(c.role, c.royal)}`}
                      style={{ animationDelay: `${Math.min(idx * 22, 480)}ms` }}
                    >
                      <span className="training2-card-dot" />
                      {rank <= 3 && <span className={`training2-rank training2-rank-${rank}`}>{rank}</span>}
                      <span className="training2-card-name">{cardLabel(c.card_slug)}</span>
                      <div className="training2-card-bar">
                        <div className="training2-card-bar-fill" style={{ width: `${barsIn ? c.win_rate * 100 : 0}%` }} />
                      </div>
                      <span className="training2-card-winrate">{pct(c.win_rate)}</span>
                      <span className={`training2-card-value ${c.ability_value > 0.0005 ? 'is-good' : c.ability_value < -0.0005 ? 'is-bad' : 'is-flat'}`}>
                        {pctSigned(c.ability_value, 1)}
                      </span>
                    </div>
                    )
                  })}
                  {cardValues && cardValues.length === 0 && (
                    <p className="training2-empty">No card values yet.</p>
                  )}
                </div>
              </div>

              <div>
                <h4 className="training2-section-title">Ability value</h4>
                <div className="training2-abilities">
                  {(abilityValues ?? []).map((a, idx) => {
                    const v = a.avg_ability_value
                    const magnitude = Math.min(50, Math.abs(v) * 100 * 6)
                    const isGood = v >= 0
                    return (
                      <div
                        key={a.ability} className="training2-ability-row training2-row-anim"
                        style={{ animationDelay: `${Math.min(idx * 30, 480)}ms` }}
                      >
                        <span className="training2-ability-name">{ABILITY_LABEL[a.ability] ?? a.ability}</span>
                        <div className="training2-ability-track">
                          <div
                            className={`training2-ability-fill ${isGood ? 'is-good' : 'is-bad'}`}
                            style={
                              isGood
                                ? { left: '50%', width: `${barsIn ? magnitude : 0}%` }
                                : { left: `${barsIn ? 50 - magnitude : 50}%`, width: `${barsIn ? magnitude : 0}%` }
                            }
                          />
                        </div>
                        <span className={`training2-ability-value ${isGood ? 'is-good' : 'is-bad'}`}>
                          {pctSigned(v)}
                        </span>
                      </div>
                    )
                  })}
                  {abilityValues && abilityValues.length === 0 && (
                    <p className="training2-empty">Not enough cards on both sides of any ability yet.</p>
                  )}
                </div>
              </div>
            </>
          )}
        </div>
      )}
    </div>
  )
}
