import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useCardsBySlug } from '../lib/useCards'
import { Avatar } from './Avatar'

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
 *    preview (0117's 'preview' training-run kind). The candidate-vs-
 *    baseline scoreline (the donut, the VS numbers, draws/unresolved) is
 *    always THIS run's own -- it's the direct answer to "did the mutation
 *    win more than the current bot, just now." But the analysis below it
 *    (card value, ability value, the per-stat-point tiles, team synergy,
 *    best decks) is pooled across every 'train'-kind run ever completed
 *    (admin_card_performance and friends, called with p_run = null -- see
 *    0115), not scoped to this one run. Jared, seeing the numbers move
 *    between clicks: "why is the value of 1 attack point increasing?
 *    Makes no sense, all values are based on it." They were being refit
 *    from scratch on nothing but that one run's own ~dozens of games every
 *    time -- inherently noisy with only 13 active cards, so the anchor
 *    itself (and everything divided by it) bounced around run to run. A
 *    regression pooled over every game this bot level has ever played is a
 *    far bigger, far more stable sample, and it only gets steadier as more
 *    runs pile up -- it just won't visibly shift on every single click
 *    anymore, which is the point.
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
interface DeltaRow { card_slug: string; delta_win_rate: number | null; has_snapshot: boolean }
interface StatMetricRow { metric: string; value: number }
interface StatDeltaRow { metric: string; delta_value: number | null; has_snapshot: boolean }
interface SynergyRow { card_a: string; card_b: string; games: number; win_rate: number; lift: number }
interface TeamRow { deck: string[]; score: number }

const ABILITY_LABEL: Record<string, string> = {
  burns: 'Burns', poisons: 'Poisons', stuns: 'Stuns', heals: 'Heals',
  parries: 'Parries', parries_all: 'Parries everything',
  crit_boost: 'Bonus crit chance', double_attack: 'Attacks twice', lifesteal: 'Lifesteal',
  regen: 'Regenerates', evasion: 'Evasion', anti_poison: 'Anti-poison bonus',
  team_aura: 'Team aura', team_buff: 'Team buff', self_buff: 'Grows over time',
  aoe_damage: 'Area damage', summons: 'Summons a structure',
}

// Jared: "a tier list, from tier A to tier F" then, correcting himself right
// after: "Actually all tiers lists should go from S-E, sorry." S is the
// best, E is the last. 13 active cards split into 6 bands BY RANK (floor(i *
// 6 / n), not a fixed value cutoff) so the bands stay populated and roughly
// even-sized no matter how bunched the roster's values happen to be.
const TIER_LETTERS = ['S', 'A', 'B', 'C', 'D', 'E'] as const
function tierOf(rankIdx: number, total: number): string {
  if (total <= 0) return 'E'
  return TIER_LETTERS[Math.min(TIER_LETTERS.length - 1, Math.floor((rankIdx * TIER_LETTERS.length) / total))]
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
// A signed integer point, Jared's "1 damage point = 1 of value" anchor --
// used once the regression's own Attack (power) coefficient is stable
// enough to divide by (see canPoints below).
function pts(n: number | null | undefined): string {
  if (n == null) return '--'
  const r = Math.round(n)
  return `${r >= 0 ? '+' : ''}${r}`
}
function pts1(n: number | null | undefined): string {
  if (n == null) return '--'
  return `${n >= 0 ? '+' : ''}${n.toFixed(1)}`
}
// A card/pair/team's own CURRENT value -- no leading "+" on a positive
// number, since that's reserved for an actual gain/delta (see pts() above).
// A negative value still shows its "-" sign.
function ptsVal(n: number | null | undefined): string {
  if (n == null) return '--'
  return `${Math.round(n)}`
}
// Same "no leading +" convention as ptsVal(), but keeping the 1-decimal
// precision the stat tiles already use (see pts1() above) -- used for the
// tiles' own current value now that the "+" they used to show unconditionally
// is reserved for the delta badge underneath instead.
function ptsVal1(n: number | null | undefined): string {
  if (n == null) return '--'
  return `${n.toFixed(1)}`
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
  const cardsBySlug = useCardsBySlug()
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
  const [synergy, setSynergy] = useState<SynergyRow[] | null>(null)
  const [bestTeams, setBestTeams] = useState<TeamRow[] | null>(null)
  const [deltas, setDeltas] = useState<DeltaRow[] | null>(null)
  const [statDeltas, setStatDeltas] = useState<StatDeltaRow[] | null>(null)
  const [barsIn, setBarsIn] = useState(false)

  const cardLabel = useCallback((slug: string) => cardsBySlug.get(slug)?.name ?? slug, [cardsBySlug])
  const cardRoyal = useCallback((slug: string) => cardsBySlug.get(slug)?.royal ?? false, [cardsBySlug])

  // Pick up where the last session left off: the latest completed Simulate
  // (preview) run's data, and the latest Train (teach) run's outcome for
  // the banner -- so reopening the tab doesn't lose either.
  useEffect(() => {
    supabase.from('training_runs').select('*')
      .eq('kind', 'preview').eq('status', 'completed')
      .order('created_at', { ascending: false }).limit(1)
      .then(({ data }) => {
        const run = (data as TrainingRun[] | null)?.[0]
        if (run) { setSimRun(run); void loadValues() }
      })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // p_run: null on every call below -- pooled across every 'train'-kind
  // run this bot level has ever completed (see 0115_training_dashboards_
  // train_only.sql), not just the run that was just clicked. See the file
  // header: this is what makes "1 Attack point" (and every points value
  // derived from it) a stable ruler instead of one that redraws itself
  // from a noisy ~dozens-of-games sample on every single click.
  async function loadValues() {
    setBarsIn(false)
    const [m, c, a, syn, teams, d, sd] = await Promise.all([
      supabase.rpc('admin_stat_value_model', { p_run: null }),
      supabase.rpc('admin_card_value', { p_run: null }),
      supabase.rpc('admin_ability_value', { p_run: null }),
      supabase.rpc('admin_pair_synergy', { p_run: null, p_min_games: 5 }),
      supabase.rpc('admin_best_teams', { p_run: null, p_n: 3, p_min_games: 5 }),
      supabase.rpc('admin_card_value_deltas', { p_run: null }),
      supabase.rpc('admin_stat_value_deltas', { p_run: null }),
    ])
    setStatModel((m.data as StatMetricRow[]) ?? null)
    setCardValues((c.data as CardValueRow[]) ?? null)
    setAbilityValues((a.data as AbilityValueRow[]) ?? null)
    setSynergy((syn.data as SynergyRow[]) ?? null)
    setBestTeams((teams.data as TeamRow[]) ?? null)
    setDeltas((d.data as DeltaRow[]) ?? null)
    setStatDeltas((sd.data as StatDeltaRow[]) ?? null)
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
      // Best-effort: a snapshot failure shouldn't block Simulate itself,
      // just leave this round's delta unavailable.
      const { error: snapErr } = await supabase.rpc('admin_snapshot_pre_batch_values')
      if (snapErr) console.warn('admin_snapshot_pre_batch_values:', snapErr.message)
      const run = await runOp(n)
      setSimRun(run)
      await loadValues()
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

  // Jared: "From now on, the value should be based on 1 HP = 1 value
  // point (VP), instead of 1 attack point = 1 value point." 1 HP is now
  // the anchor, worth exactly 1 -- every other stat, ability, card and
  // team total gets converted into that same currency by dividing its own
  // win-rate contribution by the HP coefficient. Guarded the same way
  // admin_card_value already guards it server-side: near zero, dividing
  // amplifies noise into meaningless swings, so points just aren't shown
  // yet (falls back to the raw % everywhere below).
  const intercept = statByMetric['intercept'] as number | undefined
  const hpPoint = statByMetric['hp_point'] as number | undefined
  const canPoints = hasModel && intercept != null && hpPoint != null && Math.abs(hpPoint) > 0.0001
  const toPoints = (delta: number) => (canPoints ? delta / (hpPoint as number) : null)

  const summary = simRun?.summary
  const candWins = summary?.candidate_wins ?? 0
  const baseWins = summary?.baseline_wins ?? 0
  const draws = summary?.draws ?? 0
  const unresolved = summary?.unresolved ?? 0
  const totalWB = candWins + baseWins
  const basePct = totalWB > 0 ? baseWins / totalWB : 0.5
  const candPct = totalWB > 0 ? candWins / totalWB : 0.5
  const candPctAnim = useAnimateIn(candPct, 1100)

  // Rank for the S..E tier list -- sorted by points (1 HP = 1 VP) when
  // the model is trustworthy, falling back to raw win rate otherwise.
  // This used to always sort by raw win rate: the plain, unregularized
  // regression on the real 13-card roster kept coming out wrong-signed on
  // hp_point (power/hp/range/move are genuinely correlated on the actual
  // card set, which destabilizes an unconstrained fit that small -- see
  // 0139). 0139 fixed that at the source: admin_stat_value_model now
  // shrinks the four slope coefficients toward the 65-card calibration
  // run's own proven-stable values (ridge regression to a nonzero prior)
  // instead of fitting these 13 cards in isolation, so hp_point comes out
  // reliably positive and canPoints is true in the normal case. Sorting
  // and display both key off canPoints, so if a future roster ever
  // destabilizes the fit again this still degrades to raw win rate
  // instead of showing backwards numbers.
  const rankedCards = [...(cardValues ?? [])]
    .map((c) => ({ ...c, points: canPoints ? toPoints(c.win_rate - (intercept as number)) : null }))
    .sort((a, b) => (canPoints ? (b.points as number) - (a.points as number) : b.win_rate - a.win_rate))
  const cardPoints = new Map(rankedCards.map((c) => [c.card_slug, c.points]))
  const tierGroups = new Map<string, typeof rankedCards>()
  rankedCards.forEach((c, i) => {
    const tier = tierOf(i, rankedCards.length)
    tierGroups.set(tier, [...(tierGroups.get(tier) ?? []), c])
  })
  const deltaBySlug = new Map((deltas ?? []).map((d) => [d.card_slug, d]))
  const statDeltaByMetric = new Map((statDeltas ?? []).map((d) => [d.metric, d]))
  // Mirrors the card-tile delta badge below (same is-good/is-bad/is-flat/
  // "new" convention), but for the 4 top-of-page stat-value tiles -- shows
  // how much this metric moved since the last batch that had a snapshot to
  // compare against, in the same HP-point units the tile itself uses.
  const statDeltaBadge = (metric: string) => {
    const d = statDeltaByMetric.get(metric)
    if (!d?.has_snapshot || d.delta_value == null) {
      return <span className="training2-tile-delta is-flat">new</span>
    }
    // canPoints can be false right now (hp_point coefficient too close to
    // zero to safely divide by -- see canPoints below) even though a real
    // delta exists. Previously that made this badge vanish entirely
    // (gated on the points-converted value being non-null) instead of
    // falling back to the same raw win-rate-per-point percentage the
    // tile's own current value already falls back to in that mode.
    const deltaPts = toPoints(d.delta_value)
    if (deltaPts != null) {
      const deltaRounded = Math.round(deltaPts * 10) / 10
      return (
        <span className={`training2-tile-delta ${deltaRounded > 0 ? 'is-good' : deltaRounded < 0 ? 'is-bad' : 'is-flat'}`}>
          {deltaRounded === 0 ? '±0' : pts1(deltaRounded)} vs last batch
        </span>
      )
    }
    return (
      <span className={`training2-tile-delta ${d.delta_value > 0 ? 'is-good' : d.delta_value < 0 ? 'is-bad' : 'is-flat'}`}>
        {pctSigned(d.delta_value)} vs last batch
      </span>
    )
  }

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
                <div className="training2-tile training2-tile--hp">
                  <span className="training2-tile-label">1 HP</span>
                  <span className="training2-tile-value is-good">1.0 pt</span>
                  <span className="training2-tile-note">the anchor -- 1 HP = 1 VP</span>
                  {statDeltaBadge('hp_point')}
                </div>
                {(['power', 'range', 'move'] as const).map((key) => {
                  const label = key === 'power' ? '1 Attack point' : key === 'range' ? '1 Range point' : '1 Move point'
                  const raw = statByMetric[`${key}_point`]
                  const p = canPoints && raw != null ? toPoints(raw) : null
                  return (
                    <div key={key} className={`training2-tile training2-tile--${key}`}>
                      <span className="training2-tile-label">{label}</span>
                      <span className={`training2-tile-value ${(p ?? raw ?? 0) >= 0 ? 'is-good' : 'is-bad'}`}>
                        {p != null ? `${ptsVal1(p)} pts` : pctSigned(raw)}
                      </span>
                      <span className="training2-tile-note">{p != null ? 'vs. 1 HP' : 'win rate per point'}</span>
                      {statDeltaBadge(`${key}_point`)}
                    </div>
                  )
                })}
              </div>
              <p className="training2-hint">Burn, poison, stun, heal, parry and every other ability's own value is in "Ability value" below.</p>

              <div>
                <h4 className="training2-section-title">Card value</h4>
                <div className="training2-tierlist">
                  {TIER_LETTERS.map((tier) => {
                    const rows = tierGroups.get(tier) ?? []
                    if (rows.length === 0) return null
                    return (
                      <div key={tier} className={`training2-tier-row training2-tier-${tier}`}>
                        <span className="training2-tier-badge">{tier}</span>
                        <div className="training2-tier-cards">
                          {rows.map((c) => {
                            const delta = deltaBySlug.get(c.card_slug)
                            // 0139: c.points is the same "1 HP = 1 VP"
                            // conversion the top-of-page stat tiles use,
                            // now reliable on the real roster -- falls
                            // back to raw win rate (matching rankedCards'
                            // own sort fallback above) only if canPoints
                            // is false.
                            const cardGood = c.points != null ? c.points >= 0 : c.win_rate >= 0.5
                            const deltaPts = canPoints && delta?.delta_win_rate != null ? toPoints(delta.delta_win_rate) : null
                            const deltaPtsRounded = deltaPts != null ? Math.round(deltaPts * 10) / 10 : null
                            return (
                              <div key={c.card_slug} className={`training2-card-tile ${roleClass(c.role, c.royal)}`}>
                                <Avatar
                                  slug={c.card_slug} name={cardLabel(c.card_slug)} size={60}
                                  className="training2-card-tile-avatar"
                                />
                                <span className="training2-card-tile-name">{cardLabel(c.card_slug)}</span>
                                <span className={`training2-card-tile-value ${cardGood ? 'is-good' : 'is-bad'}`}>
                                  {c.points != null ? `${ptsVal1(c.points)} pts` : pct(c.win_rate, 1)}
                                </span>
                                <span className="training2-card-tile-note">{c.points != null ? 'value' : 'win rate'}</span>
                                {!delta?.has_snapshot || delta.delta_win_rate == null ? (
                                  <span className="training2-card-tile-delta is-flat">new</span>
                                ) : deltaPtsRounded != null ? (
                                  <span className={`training2-card-tile-delta ${deltaPtsRounded > 0 ? 'is-good' : deltaPtsRounded < 0 ? 'is-bad' : 'is-flat'}`}>
                                    {deltaPtsRounded === 0 ? '±0' : pts1(deltaPtsRounded)} vs last batch
                                  </span>
                                ) : (
                                  <span className={`training2-card-tile-delta ${delta.delta_win_rate > 0 ? 'is-good' : delta.delta_win_rate < 0 ? 'is-bad' : 'is-flat'}`}>
                                    {pctSigned(delta.delta_win_rate)} vs last batch
                                  </span>
                                )}
                              </div>
                            )
                          })}
                        </div>
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
                    const p = toPoints(v)
                    const magnitude = Math.min(50, Math.abs(v) * 100 * 6)
                    const isGood = (p ?? v) >= 0
                    return (
                      <div
                        key={a.ability} className="training2-ability-row training2-row-anim"
                        style={{ animationDelay: `${Math.min(idx * 30, 480)}ms` }}
                      >
                        <span className="training2-ability-name">
                          {ABILITY_LABEL[a.ability] ?? a.ability}
                          <span className="training2-ability-n">{a.cards_with} card{a.cards_with === 1 ? '' : 's'}</span>
                        </span>
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
                          {p != null ? `${pts(p)} pts` : pctSigned(v)}
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

          {synergy && synergy.length > 0 && (
            <div>
              <h4 className="training2-section-title">Team synergy</h4>
              <div className="training2-pairs">
                <p className="training2-subhead">Strongest pairs</p>
                <div className="training2-pair-grid">
                  {synergy.slice(0, 5).map((s, idx) => {
                    const p = toPoints(s.lift)
                    const isGood = (p ?? s.lift) >= 0
                    const pa = cardPoints.get(s.card_a) ?? null
                    const pb = cardPoints.get(s.card_b) ?? null
                    return (
                      <div
                        key={`${s.card_a}-${s.card_b}`} className="training2-pair-tile training2-row-anim"
                        style={{ animationDelay: `${Math.min(idx * 40, 480)}ms` }}
                      >
                        <div className="training2-pair-unit">
                          <Avatar slug={s.card_a} name={cardLabel(s.card_a)} size={52} className="training2-pair-avatar" />
                          <span className="training2-pair-unit-name">{cardLabel(s.card_a)}</span>
                          <span className="training2-pair-unit-value">{pa != null ? `${ptsVal(pa)} pts` : '--'}</span>
                        </div>
                        <span className="training2-pair-plus">+</span>
                        <div className="training2-pair-unit">
                          <Avatar slug={s.card_b} name={cardLabel(s.card_b)} size={52} className="training2-pair-avatar" />
                          <span className="training2-pair-unit-name">{cardLabel(s.card_b)}</span>
                          <span className="training2-pair-unit-value">{pb != null ? `${ptsVal(pb)} pts` : '--'}</span>
                        </div>
                        <div className="training2-pair-bonus">
                          <span className="training2-pair-bonus-label">Together</span>
                          <span className={`training2-pair-bonus-value ${isGood ? 'is-good' : 'is-bad'}`}>
                            {p != null ? `${pts(p)} pts` : pctSigned(s.lift)}
                          </span>
                          <span className="training2-pair-games">{s.games.toLocaleString()} games</span>
                        </div>
                      </div>
                    )
                  })}
                </div>
                {synergy.length > 5 && (
                  <>
                    <p className="training2-subhead">Weakest pairs</p>
                    <div className="training2-pair-grid">
                      {synergy.slice(Math.max(5, synergy.length - 5)).reverse().map((s, idx) => {
                        const p = toPoints(s.lift)
                        const isGood = (p ?? s.lift) >= 0
                        const pa = cardPoints.get(s.card_a) ?? null
                        const pb = cardPoints.get(s.card_b) ?? null
                        return (
                          <div
                            key={`${s.card_a}-${s.card_b}`} className="training2-pair-tile training2-row-anim"
                            style={{ animationDelay: `${Math.min(idx * 40, 480)}ms` }}
                          >
                            <div className="training2-pair-unit">
                              <Avatar slug={s.card_a} name={cardLabel(s.card_a)} size={52} className="training2-pair-avatar" />
                              <span className="training2-pair-unit-name">{cardLabel(s.card_a)}</span>
                              <span className="training2-pair-unit-value">{pa != null ? `${ptsVal(pa)} pts` : '--'}</span>
                            </div>
                            <span className="training2-pair-plus">+</span>
                            <div className="training2-pair-unit">
                              <Avatar slug={s.card_b} name={cardLabel(s.card_b)} size={52} className="training2-pair-avatar" />
                              <span className="training2-pair-unit-name">{cardLabel(s.card_b)}</span>
                              <span className="training2-pair-unit-value">{pb != null ? `${ptsVal(pb)} pts` : '--'}</span>
                            </div>
                            <div className="training2-pair-bonus">
                              <span className="training2-pair-bonus-label">Together</span>
                              <span className={`training2-pair-bonus-value ${isGood ? 'is-good' : 'is-bad'}`}>
                                {p != null ? `${pts(p)} pts` : pctSigned(s.lift)}
                              </span>
                              <span className="training2-pair-games">{s.games.toLocaleString()} games</span>
                          </div>
                          </div>
                        )
                      })}
                    </div>
                  </>
                )}
              </div>
            </div>
          )}

          {bestTeams && bestTeams.length > 0 && (
            <div>
              <h4 className="training2-section-title">Best decks</h4>
              <div className="training2-teamtiles">
                {bestTeams.map((t, idx) => {
                  const p = toPoints(t.score)
                  const isGood = (p ?? t.score) >= 0
                  const ordered = [...t.deck].sort((a, b) => Number(cardRoyal(b)) - Number(cardRoyal(a)))
                  return (
                    <div
                      key={idx} className="training2-teamtile training2-row-anim"
                      style={{ animationDelay: `${Math.min(idx * 60, 480)}ms` }}
                    >
                      <span className="training2-teamtile-rank">#{idx + 1}</span>
                      <div className="training2-teamtile-units">
                        {ordered.map((slug) => {
                          const up = cardPoints.get(slug) ?? null
                          return (
                            <div key={slug} className="training2-teamtile-unit">
                              <Avatar slug={slug} name={cardLabel(slug)} size={48} className="training2-teamtile-avatar" />
                              <span className="training2-teamtile-unit-name">{cardLabel(slug)}</span>
                              <span className="training2-teamtile-unit-value">{up != null ? `${ptsVal(up)} pts` : '--'}</span>
                            </div>
                          )
                        })}
                      </div>
                      <div className="training2-teamtile-total">
                        <span className="training2-teamtile-total-label">Team synergy</span>
                        <span className={`training2-teamtile-total-value ${isGood ? 'is-good' : 'is-bad'}`}>
                          {p != null ? `${pts(p)} pts` : pctSigned(t.score)}
                        </span>
                      </div>
                    </div>
                  )
                })}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
