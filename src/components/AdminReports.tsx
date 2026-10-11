import { useCallback, useEffect, useState } from 'react'
import { adminReports, adminResolveReport, adminSetBanned, type AdminReport } from '../lib/api'

type View = 'open' | 'actioned' | 'dismissed'
const REASON: Record<string, string> = {
  cheating: 'Cheating', offensive_name: 'Offensive name', offensive_profile: 'Offensive profile',
  harassment: 'Harassment', spam: 'Spam', other: 'Other',
}
const ago = (iso: string) => {
  const m = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000))
  return m < 60 ? `${m}m ago` : m < 1440 ? `${Math.round(m / 60)}h ago` : `${Math.round(m / 1440)}d ago`
}

/**
 * Admin Mode -> Reports (0217). What players sent from a profile card. Open
 * reports first; "Ban" bans the reported account (same switch as the Users tab)
 * and marks the report actioned, "Dismiss" closes it with no action. The count
 * beside a name is how many reports that account got in the last 30 days.
 */
export function AdminReports() {
  const [view, setView] = useState<View>('open')
  const [rows, setRows] = useState<AdminReport[] | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  const load = useCallback(() => {
    adminReports(view).then(setRows).catch((e) => setErr((e as Error).message))
  }, [view])
  useEffect(() => { setRows(null); setErr(null); load() }, [load])

  async function act(r: AdminReport, status: 'actioned' | 'dismissed' | 'open', ban?: boolean) {
    setBusy(r.id); setErr(null)
    try {
      if (ban) await adminSetBanned(r.reported_id, true)
      await adminResolveReport(r.id, status, ban ? 'banned' : null)
      load()
    } catch (e) { setErr((e as Error).message) }
    finally { setBusy(null) }
  }

  return (
    <div className="admin-reports">
      <h2>Reports</h2>
      <div className="seg" role="radiogroup" aria-label="Status">
        {(['open', 'actioned', 'dismissed'] as View[]).map((v) => (
          <button key={v} type="button" role="radio" aria-checked={view === v}
                  className={view === v ? 'is-on' : ''} onClick={() => setView(v)}>
            {v === 'open' ? 'Open' : v === 'actioned' ? 'Actioned' : 'Dismissed'}
          </button>
        ))}
      </div>
      {err && <p className="error tiny">{err}</p>}
      {!rows && !err && <p className="muted">Loading…</p>}
      {rows && rows.length === 0 && <p className="muted">Nothing here.</p>}
      <ul className="rep-list">
        {rows?.map((r) => (
          <li key={r.id} className="rep-item">
            <div className="rep-top">
              <b>{r.reported ?? 'Unknown'}</b>
              {r.reported_banned && <span className="rep-chip is-banned">banned</span>}
              <span className="rep-chip">{REASON[r.reason] ?? r.reason}</span>
              {r.reports_30d > 1 && <span className="rep-chip is-warn">{r.reports_30d} reports in 30 days</span>}
              <span className="muted tiny rep-when">{ago(r.created_at)}</span>
            </div>
            <div className="muted tiny">from {r.reporter ?? 'unknown'}{r.match_id ? ' · during a match' : ''}</div>
            {r.details && <p className="rep-details">{r.details}</p>}
            {r.status !== 'open' && <div className="muted tiny">{r.status}{r.note ? ` (${r.note})` : ''}</div>}
            <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
              {r.status === 'open' ? (
                <>
                  {!r.reported_banned && (
                    <button className="btn danger" disabled={busy === r.id}
                            onClick={() => void act(r, 'actioned', true)}>Ban player</button>
                  )}
                  <button className="btn ghost" disabled={busy === r.id}
                          onClick={() => void act(r, 'actioned')}>Mark handled</button>
                  <button className="btn ghost" disabled={busy === r.id}
                          onClick={() => void act(r, 'dismissed')}>Dismiss</button>
                </>
              ) : (
                <button className="btn ghost" disabled={busy === r.id} onClick={() => void act(r, 'open')}>Reopen</button>
              )}
            </div>
          </li>
        ))}
      </ul>
    </div>
  )
}
