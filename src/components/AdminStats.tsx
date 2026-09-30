import { useEffect, useState } from 'react'
import {
  adminActivitySummary, adminListFeedback, adminPlayerActivity, adminReplyFeedback, adminResolveFeedback,
} from '../lib/api'
import { isOnline } from '../lib/useFriends'
import { nameColorStyle } from '../lib/nameColors'
import type { AdminActivitySummary, AdminFeedbackRow, AdminPlayerActivityRow } from '../lib/types'
import {
  IconBolt, IconFlag, IconPeople, IconPersonPlus, IconSparkle, IconSword, IconTrophy,
} from './Icons'

/**
 * Activity. Jared: "as an admin, I think it would be cool to know all the
 * data that is happening in the game... last connection of each player,
 * how many matches they have played, how many matches were played in each
 * day, statistics summaries by day, week, month. Also, any data that could
 * be cool to know so that I can improve the game and adjust accordingly."
 *
 * IN ENGLISH ONLY, same as every other tab behind this door -- see
 * AdminUsers.tsx's own comment on that.
 *
 * Three server calls (see 0169_admin_activity_and_feedback.sql): a totals +
 * day-by-day series (admin_activity_summary), the full player roster with
 * last-connection and match counts (admin_player_activity), and the
 * feedback/bug inbox that the Settings button below now feeds
 * (admin_list_feedback). Week/month are rolled up client-side out of the
 * same daily series the chart already has -- summing groups of days is
 * simpler and just as correct as asking the server for three separate
 * grouping levels, and it means switching the range never costs a second
 * round trip.
 */
export function AdminStats() {
  const [days, setDays] = useState(30)
  const [summary, setSummary] = useState<AdminActivitySummary | null>(null)
  const [players, setPlayers] = useState<AdminPlayerActivityRow[]>([])
  const [feedback, setFeedback] = useState<AdminFeedbackRow[]>([])
  const [sort, setSort] = useState<'seen' | 'joined' | 'matches' | 'rating'>('seen')
  const [busyFeedback, setBusyFeedback] = useState<string | null>(null)
  const [replyDrafts, setReplyDrafts] = useState<Record<string, string>>({})
  const [busyReply, setBusyReply] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  async function load() {
    setErr(null)
    try {
      const [s, p, f] = await Promise.all([
        adminActivitySummary(days), adminPlayerActivity(), adminListFeedback(),
      ])
      setSummary(s); setPlayers(p); setFeedback(f)
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { void load() }, [days])

  async function toggleFeedback(id: string, resolved: boolean) {
    setBusyFeedback(id)
    try {
      await adminResolveFeedback(id, resolved)
      setFeedback((rows) => rows.map((r) => (r.id === id ? { ...r, resolved } : r)))
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setBusyFeedback(null)
    }
  }

  /** Jared: "if I respond to them through the game... my responses are
   *  sent to them as emails." Saves the reply, clears that row's draft on
   *  success, and folds the returned row (admin_reply/replied_at) straight
   *  back into state -- adminReplyFeedback fires the actual email itself,
   *  see api.ts. */
  async function sendReply(id: string) {
    const reply = (replyDrafts[id] ?? '').trim()
    if (!reply) return
    setBusyReply(id)
    try {
      const row = await adminReplyFeedback(id, reply)
      setFeedback((rows) => rows.map((r) => (r.id === id ? { ...r, ...row } : r)))
      setReplyDrafts((d) => { const next = { ...d }; delete next[id]; return next })
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setBusyReply(null)
    }
  }

  const sortedPlayers = players.slice().sort((a, b) => {
    if (sort === 'joined') return b.created_at.localeCompare(a.created_at)
    if (sort === 'matches') return (b.matches_1v1 + b.matches_royale) - (a.matches_1v1 + a.matches_royale)
    if (sort === 'rating') return b.rating - a.rating
    return (b.last_seen_at ?? '').localeCompare(a.last_seen_at ?? '')
  })

  const pendingFeedback = feedback.filter((f) => !f.resolved)
  const resolvedFeedback = feedback.filter((f) => f.resolved)

  if (loading) return <div className="admin-stats"><p className="muted tiny">Loading…</p></div>

  return (
    <div className="admin-stats">
      {summary && (
        <>
          <section className="admin-section">
            <h3 className="admin-h3">Overview</h3>
            <div className="admin-statcards">
              <StatCard i={0} icon={<IconPeople />} color="var(--nc-blue)" label="Registered players" value={summary.totals.players} />
              <StatCard i={1} icon={<IconSword />} color="var(--you)" label="1v1 matches played" value={summary.totals.matches1v1} />
              <StatCard i={2} icon={<IconSparkle />} color="var(--nc-orange)" label="Royale matches played" value={summary.totals.matchesRoyale} />
              <StatCard i={3} icon={<IconTrophy />} color="var(--nc-purple)" label="Tournaments finished" value={summary.totals.tournamentsFinished} />
              <StatCard i={4} icon={<IconBolt />} color="var(--nc-green)" label="Online now / last 24h" value={summary.totals.dau} note="DAU" />
              <StatCard i={5} icon={<IconBolt />} color="var(--nc-green)" label="Active last 7 days" value={summary.totals.wau} note="WAU" />
              <StatCard i={6} icon={<IconBolt />} color="var(--nc-green)" label="Active last 30 days" value={summary.totals.mau} note="MAU" />
              <StatCard i={7} icon={<IconPersonPlus />} color="var(--nc-sky)" label="Signups today" value={summary.totals.signupsToday} />
              <StatCard i={8} icon={<IconPersonPlus />} color="var(--nc-sky)" label="Signups last 7 days" value={summary.totals.signups7d} />
              <StatCard i={9} icon={<IconPersonPlus />} color="var(--nc-sky)" label="Signups last 30 days" value={summary.totals.signups30d} />
              <StatCard
                i={10} icon={<IconFlag />} color="var(--danger)"
                label="Open feedback / bugs" value={summary.totals.openFeedback}
                pulse={summary.totals.openFeedback > 0}
              />
            </div>
            <p className="muted tiny admin-wide">
              DAU/WAU/MAU read the account's LAST connection right now -- there is no login
              history to look back on, so those three are always "as of this moment," not a
              trend. The daily chart below is the real trend line.
            </p>
          </section>

          <section className="admin-section">
            <div className="admin-sectionrow">
              <h3 className="admin-h3">Match volume, by day</h3>
              <div className="seg admin-rangeseg" role="radiogroup" aria-label="Range">
                {[7, 14, 30, 90].map((n) => (
                  <button
                    key={n} type="button" role="radio" aria-checked={days === n}
                    className={days === n ? 'is-on' : ''} onClick={() => setDays(n)}
                  >
                    {n}d
                  </button>
                ))}
              </div>
            </div>
            <DailyChart daily={summary.daily} />
            <RollupTable daily={summary.daily} />
            <p className="muted tiny admin-wide">
              Match types (all-time, mutually exclusive): {summary.matchTypes.ranked} ranked PvP
              · {summary.matchTypes.casual} casual PvP · {summary.matchTypes.botPractice} vs a bot
              (ranked fallback included).
            </p>
          </section>
        </>
      )}

      <section className="admin-section">
        <div className="admin-sectionrow">
          <h3 className="admin-h3">Feedback &amp; bug reports ({pendingFeedback.length} open)</h3>
        </div>
        {feedback.length === 0 ? (
          <p className="muted tiny">Nothing sent in yet.</p>
        ) : (
          <ul className="admin-list admin-feedbacklist">
            {[...pendingFeedback, ...resolvedFeedback].map((f) => (
              <li
                key={f.id} data-kind={f.kind}
                className={`admin-feedbackrow${f.resolved ? ' is-retired' : ''}`}
              >
                <div className="admin-feedback-head">
                  <span className={`admin-tag admin-tag-${f.kind}`}>
                    {f.kind === 'bug' ? 'bug' : 'feedback'}
                  </span>
                  <span className="admin-rowname" style={nameColorStyle(f.name_color)}>{f.username}</span>
                  <span className="muted tiny">{f.email}</span>
                  <span className="muted tiny">{new Date(f.created_at).toLocaleString()}</span>
                </div>
                <p className="admin-feedback-msg">{f.message}</p>
                {f.admin_reply && (
                  <div className="admin-feedback-reply">
                    <span className="muted tiny">
                      Your reply{f.replied_at && ` · ${new Date(f.replied_at).toLocaleString()}`}
                    </span>
                    <p className="admin-feedback-msg">{f.admin_reply}</p>
                  </div>
                )}
                <div className="admin-feedback-actions">
                  <button
                    type="button" className="btn tiny ghost" disabled={busyFeedback === f.id}
                    onClick={() => void toggleFeedback(f.id, !f.resolved)}
                  >
                    {f.resolved ? 'Mark unresolved' : 'Mark resolved'}
                  </button>
                </div>
                <div className="admin-feedback-replyform">
                  <textarea
                    className="admin-feedback-replyinput"
                    rows={2} maxLength={4000} disabled={busyReply === f.id}
                    placeholder={f.admin_reply ? 'Send another reply (replaces the one above)…' : 'Write a reply — sent to their email…'}
                    value={replyDrafts[f.id] ?? ''}
                    onChange={(e) => setReplyDrafts((d) => ({ ...d, [f.id]: e.target.value }))}
                  />
                  <button
                    type="button" className="btn tiny primary"
                    disabled={busyReply === f.id || !(replyDrafts[f.id] ?? '').trim()}
                    onClick={() => void sendReply(f.id)}
                  >
                    {busyReply === f.id ? 'Sending…' : 'Send reply'}
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="admin-section">
        <div className="admin-sectionrow">
          <h3 className="admin-h3">Players ({players.length})</h3>
          <div className="seg admin-rangeseg" role="radiogroup" aria-label="Sort by">
            {([['seen', 'Last seen'], ['joined', 'Newest'], ['matches', 'Most matches'], ['rating', 'Rating']] as const).map(([v, label]) => (
              <button
                key={v} type="button" role="radio" aria-checked={sort === v}
                className={sort === v ? 'is-on' : ''} onClick={() => setSort(v)}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
        <div className="admin-playertable-wrap">
          <table className="admin-playertable">
            <thead>
              <tr>
                <th>Player</th>
                <th>Last connection</th>
                <th>Joined</th>
                <th>Rating</th>
                <th>W-L</th>
                <th>1v1</th>
                <th>Royale</th>
                <th>Cups</th>
              </tr>
            </thead>
            <tbody>
              {sortedPlayers.map((p) => {
                const online = isOnline(p.last_seen_at ?? undefined)
                return (
                  <tr key={p.id}>
                    <td>
                      <span className="admin-rowname" style={nameColorStyle(p.name_color)}>{p.username}</span>
                      {p.is_admin && <span className="admin-tag">admin</span>}
                      {p.is_banned && <span className="admin-tag">banned</span>}
                    </td>
                    <td>
                      <span className={`presence-dot${online ? ' is-on' : ''}`} aria-hidden="true" />
                      {online ? 'Online now' : englishTimeAgo(p.last_seen_at)}
                    </td>
                    <td className="muted">{new Date(p.created_at).toLocaleDateString()}</td>
                    <td>{p.rating}</td>
                    <td>{p.wins}-{p.losses}</td>
                    <td>{p.matches_1v1}</td>
                    <td>{p.matches_royale}</td>
                    <td>{p.tournaments || '—'}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </section>

      {err && <p className="error tiny">{err}</p>}
    </div>
  )
}

/** i is the tile's own position in the grid -- staggers its entrance
 *  animation a beat behind the one before it (CSS reads it off
 *  animation-delay) so the row fills in left-to-right/top-to-bottom rather
 *  than every tile popping at once. `pulse` is only ever true for "Open
 *  feedback / bugs" right now, when there's actually something waiting --
 *  Jared: "make things pop" -- a still tile for a zero and a gently
 *  breathing one the moment a report comes in reads as "this one wants a
 *  look" without resorting to a modal or a badge count. */
function StatCard({ icon, color, label, value, note, i, pulse }: {
  icon: React.ReactNode
  color: string
  label: string
  value: number
  note?: string
  i: number
  pulse?: boolean
}) {
  return (
    <div
      className={`admin-statcard${pulse ? ' is-pulse' : ''}`}
      style={{ '--tint': color, animationDelay: `${i * 35}ms` } as React.CSSProperties}
    >
      <span className="admin-statcard-icon">{icon}</span>
      <span className="admin-statcard-value">{value}</span>
      <span className="admin-statcard-label">{label}{note && <em> ({note})</em>}</span>
    </div>
  )
}

/** English-only "3h ago" -- see src/lib/timeAgo.ts for the i18n version
 *  every player-facing screen uses. This tab is admin-only and never calls
 *  t() (see the file header), so this is that same math without the
 *  dictionary lookups. */
function englishTimeAgo(iso: string | null): string {
  if (!iso) return 'Never'
  const ms = Date.now() - new Date(iso).getTime()
  const min = Math.floor(ms / 60_000)
  if (min < 1) return 'just now'
  if (min < 60) return `${min}m ago`
  const hr = Math.floor(min / 60)
  if (hr < 24) return `${hr}h ago`
  const days = Math.floor(hr / 24)
  return `${days}d ago`
}

/** A stacked bar per day: 1v1 (blue, `--you` -- the same "your side" blue
 *  used everywhere else in this game) on the bottom, Royale (`--nc-orange`,
 *  already a theme-adaptive warm tone used elsewhere for name colours) on
 *  top, a 2px surface gap between the two segments. No drawn axis -- the
 *  bars are the axis; a `<title>` on each segment is the hover/tap detail
 *  (native tooltip, zero extra markup) since this is a small admin-only
 *  utility chart, not a public-facing deliverable that needs a custom
 *  crosshair layer. */
function DailyChart({ daily }: { daily: { date: string; matches1v1: number; matchesRoyale: number }[] }) {
  const max = Math.max(1, ...daily.map((d) => d.matches1v1 + d.matchesRoyale))
  const showEveryNth = daily.length > 20 ? Math.ceil(daily.length / 10) : daily.length > 10 ? 2 : 1
  return (
    <div className="admin-chart">
      <div className="admin-chart-legend">
        <span><i className="admin-chart-swatch" style={{ background: 'var(--you)' }} />1v1</span>
        <span><i className="admin-chart-swatch" style={{ background: 'var(--nc-orange)' }} />Royale</span>
      </div>
      <div className="admin-chart-bars">
        {daily.map((d, i) => {
          const total = d.matches1v1 + d.matchesRoyale
          const h1 = (d.matches1v1 / max) * 100
          const h2 = (d.matchesRoyale / max) * 100
          const label = new Date(`${d.date}T00:00:00`).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
          return (
            <div key={d.date} className="admin-chart-col" title={`${label}: ${total} match${total === 1 ? '' : 'es'}`}>
              <div className="admin-chart-stack">
                {d.matchesRoyale > 0 && (
                  <div
                    className="admin-chart-seg"
                    style={{ height: `${h2}%`, background: 'var(--nc-orange)', '--d': `${i * 12}ms` } as React.CSSProperties}
                  />
                )}
                {d.matchesRoyale > 0 && d.matches1v1 > 0 && <div className="admin-chart-gap" />}
                {d.matches1v1 > 0 && (
                  <div
                    className="admin-chart-seg"
                    style={{ height: `${h1}%`, background: 'var(--you)', '--d': `${i * 12}ms` } as React.CSSProperties}
                  />
                )}
              </div>
              <span className="admin-chart-daylabel">{i % showEveryNth === 0 ? label : ''}</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}

/** Weekly and monthly totals, rolled up client-side from the same daily
 *  series the chart above already has -- see this file's own header for
 *  why that beats a second/third SQL grouping level. Weeks are simple
 *  trailing 7-day buckets counted back from the newest day in `daily`
 *  (not calendar weeks -- the window itself can start on any weekday, so
 *  a calendar-week bucket would render one truncated week at each end). */
function RollupTable({ daily }: { daily: { date: string; matches1v1: number; matchesRoyale: number; signups: number }[] }) {
  if (daily.length < 7) return null
  const totalOf = (rows: typeof daily) => rows.reduce(
    (acc, d) => ({
      matches: acc.matches + d.matches1v1 + d.matchesRoyale,
      signups: acc.signups + d.signups,
    }),
    { matches: 0, signups: 0 },
  )
  const weeks: { label: string; matches: number; signups: number }[] = []
  for (let end = daily.length; end > 0; end -= 7) {
    const start = Math.max(0, end - 7)
    const chunk = daily.slice(start, end)
    if (chunk.length === 0) continue
    const t = totalOf(chunk)
    weeks.unshift({ label: `${chunk[0].date} → ${chunk[chunk.length - 1].date}`, matches: t.matches, signups: t.signups })
  }
  const monthTotal = totalOf(daily)
  return (
    <div className="admin-rollup">
      <table className="admin-playertable admin-rollup-table">
        <thead><tr><th>Week</th><th>Matches</th><th>Signups</th></tr></thead>
        <tbody>
          {weeks.map((w) => (
            <tr key={w.label}><td className="muted tiny">{w.label}</td><td>{w.matches}</td><td>{w.signups}</td></tr>
          ))}
          <tr className="admin-rollup-total">
            <td>Whole range ({daily.length}d)</td><td>{monthTotal.matches}</td><td>{monthTotal.signups}</td>
          </tr>
        </tbody>
      </table>
    </div>
  )
}
