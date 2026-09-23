import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import {
  adminListBanAppeals, adminListBanned, adminResolveBanAppeal, adminSetBanned, adminSetRating,
  adminUpdateProfile, getRating,
} from '../lib/api'
import type { AdminBanAppealRow, Profile } from '../lib/types'
import { nameColorStyle } from '../lib/nameColors'

/**
 * User & Security Management. Jared's account only -- see AdminPanel.tsx and
 * cn_is_super_admin() for where that is actually decided; this screen just
 * trusts it, the same way AdminCards trusts the door it is behind.
 *
 * IN ENGLISH ONLY, for the same reason AdminCards is: read by one person.
 *
 * There is no "list everyone" here on purpose. `profiles` has been readable
 * by any signed-in player since 0001 (that is what makes the ladder and
 * spectating work), so a search box costs nothing this table was not already
 * exposed to -- but an unfiltered admin screen that dumps every account onto
 * the page the moment it opens is a worse habit to build than a search box
 * is an inconvenience to use.
 */

interface Draft {
  username: string
  avatar: string
  // 0082: rating lives in player_rating now, not on the Profile row -- this
  // is the one field in this form that isn't just read off `p`, which is
  // why open() below is async where it never had to be before.
  rating: string
  wins: string
  losses: string
  games: string
  streak: string
  achievements: string
}

function draftOf(p: Profile, rating: number): Draft {
  return {
    username: p.username,
    avatar: p.avatar ?? '',
    rating: String(rating),
    wins: String(p.wins),
    losses: String(p.losses),
    games: String(p.games),
    streak: String(p.streak),
    achievements: (p.achievements ?? []).join(', '),
  }
}

export function AdminUsers() {
  const [q, setQ] = useState('')
  const [rows, setRows] = useState<Profile[]>([])
  const [openId, setOpenId] = useState<string | null>(null)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [confirmBan, setConfirmBan] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  // The banned list and the appeal queue -- see 0062_ban_appeals.sql. Both
  // come from admin-only RPCs (there is no RLS to lean on here, same as
  // everywhere else on this table), loaded once on open and again after
  // anything that could change either of them: a ban/unban toggle below, or
  // resolving an appeal.
  const [banned, setBanned] = useState<Profile[]>([])
  const [appeals, setAppeals] = useState<AdminBanAppealRow[]>([])
  const [appealBusy, setAppealBusy] = useState<string | null>(null)
  const [appealErr, setAppealErr] = useState<string | null>(null)

  const loadBanned = useCallback(async () => {
    try {
      const [b, a] = await Promise.all([adminListBanned(), adminListBanAppeals()])
      setBanned(b)
      setAppeals(a)
    } catch (e) {
      setAppealErr((e as Error).message.replace(/^.*?:\s*/, ''))
    }
  }, [])

  useEffect(() => { void loadBanned() }, [loadBanned])

  async function resolveAppeal(id: string, approve: boolean) {
    setAppealBusy(id); setAppealErr(null)
    try {
      await adminResolveBanAppeal(id, approve)
      await loadBanned()
    } catch (e) {
      setAppealErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setAppealBusy(null)
    }
  }

  const search = useCallback(async () => {
    setBusy(true); setErr(null); setNote(null)
    const { data, error } = await supabase
      .from('profiles').select('*')
      .ilike('username', `%${q.trim()}%`)
      .order('username')
      .limit(50)
    setBusy(false)
    if (error) { setErr(error.message); return }
    setRows((data ?? []) as Profile[])
  }, [q])

  async function open(r: Profile) {
    setErr(null); setNote(null); setConfirmBan(null)
    setOpenId(r.id)
    setDraft(draftOf(r, 1000))
    const rating = await getRating(r.id)
    // The account can be closed again, or a different one opened, before
    // this resolves -- only apply it if we're still looking at the same row.
    setOpenId((id) => { if (id === r.id) setDraft(draftOf(r, rating)); return id })
  }

  // Same as `open`, but for a row that came from the banned list rather than
  // a search -- it is not necessarily in `rows` yet, so it is added there
  // first (openRow below reads off `rows`, same as every other row does).
  function openBanned(r: Profile) {
    setRows((rs) => (rs.some((x) => x.id === r.id) ? rs : [...rs, r]))
    void open(r)
  }

  function patchRow(next: Profile) {
    setRows((rs) => rs.map((r) => (r.id === next.id ? next : r)))
  }

  async function save() {
    if (!openId || !draft) return
    setBusy(true); setErr(null); setNote(null)
    try {
      const ratingNum = Number(draft.rating)
      const rating = await adminSetRating(
        openId, Number.isFinite(ratingNum) ? Math.max(0, Math.round(ratingNum)) : 1000,
      )
      const updated = await adminUpdateProfile({
        id: openId,
        username: draft.username,
        avatar: draft.avatar.trim() || undefined,
        clearAvatar: draft.avatar.trim() === '',
        wins: Number(draft.wins) || 0,
        losses: Number(draft.losses) || 0,
        games: Number(draft.games) || 0,
        streak: Number(draft.streak) || 0,
        achievements: draft.achievements.split(',').map((s) => s.trim()).filter(Boolean),
      })
      patchRow(updated)
      setDraft(draftOf(updated, rating))
      setNote(`Saved ${updated.username}.`)
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setBusy(false)
    }
  }

  async function toggleBan(r: Profile) {
    setBusy(true); setErr(null); setNote(null)
    try {
      const updated = await adminSetBanned(r.id, !r.is_banned)
      patchRow(updated)
      setNote(updated.is_banned ? `${updated.username} is banned.` : `${updated.username} is unbanned.`)
      void loadBanned()
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setBusy(false); setConfirmBan(null)
    }
  }

  const openRow = rows.find((r) => r.id === openId) ?? null

  const pendingAppeals = appeals.filter((a) => a.status === 'pending')

  return (
    <div className="admin-users">
      <section className="admin-section">
        <h3 className="admin-h3">Banned accounts ({banned.length})</h3>
        {banned.length === 0 ? (
          <p className="muted tiny">Nobody is banned right now.</p>
        ) : (
          <div className="admin-list">
            {banned.map((r) => (
              <button
                key={r.id} type="button"
                className={`admin-row is-retired${r.id === openId ? ' is-open' : ''}`}
                onClick={() => openBanned(r)}
              >
                <span className="admin-rowname" style={nameColorStyle(r.name_color)}>{r.username}</span>
                <span className="admin-tag">banned</span>
              </button>
            ))}
          </div>
        )}
      </section>

      <section className="admin-section">
        <h3 className="admin-h3">Ban appeals ({pendingAppeals.length} pending)</h3>
        {pendingAppeals.length === 0 ? (
          <p className="muted tiny">No pending appeals.</p>
        ) : (
          <ul className="admin-list admin-appeallist">
            {pendingAppeals.map((a) => (
              <li key={a.id} className="admin-appeal-row">
                <div className="admin-appeal-head">
                  <span className="admin-rowname">{a.username}</span>
                  <span className="muted tiny">{new Date(a.created_at).toLocaleString()}</span>
                </div>
                <p className="admin-appeal-msg">{a.message}</p>
                <div className="actionbar admin-acts">
                  <button
                    type="button" className="btn small" disabled={appealBusy === a.id}
                    onClick={() => void resolveAppeal(a.id, true)}
                  >
                    {appealBusy === a.id ? 'Working…' : 'Approve (unban)'}
                  </button>
                  <button
                    type="button" className="btn ghost small" disabled={appealBusy === a.id}
                    onClick={() => void resolveAppeal(a.id, false)}
                  >
                    Deny
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
        {appealErr && <p className="error tiny">{appealErr}</p>}
      </section>

      <form className="admin-usersearch" onSubmit={(e) => { e.preventDefault(); void search() }}>
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search by username…" />
        <button className="btn small" disabled={busy}>{busy ? 'Searching…' : 'Search'}</button>
      </form>

      <div className="admin-grid admin-userlayout">
        <div className="admin-list">
          {rows.map((r) => (
            <button
              key={r.id} type="button"
              className={`admin-row${r.id === openId ? ' is-open' : ''}${r.is_banned ? ' is-retired' : ''}`}
              onClick={() => void open(r)}
            >
              <span className="admin-rowname" style={nameColorStyle(r.name_color)}>{r.username}</span>
              {r.is_admin && <span className="admin-tag">admin</span>}
              {r.is_banned && <span className="admin-tag">banned</span>}
            </button>
          ))}
          {rows.length === 0 && <p className="muted tiny">Search for an account by username.</p>}
        </div>

        {openRow && draft && (
          <form className="admin-form" onSubmit={(e) => { e.preventDefault(); void save() }}>
            <div className="admin-grid">
              <label><span>Username</span>
                <input value={draft.username} onChange={(e) => setDraft({ ...draft, username: e.target.value })} />
              </label>
              <label><span>Avatar (a card slug, or blank)</span>
                <input value={draft.avatar} onChange={(e) => setDraft({ ...draft, avatar: e.target.value })} />
              </label>
            </div>
            <div className="admin-grid admin-nums">
              <label><span>Rating</span>
                <input
                  type="number" value={draft.rating}
                  onChange={(e) => setDraft({ ...draft, rating: e.target.value })}
                />
              </label>
              <label><span>Wins</span>
                <input type="number" value={draft.wins} onChange={(e) => setDraft({ ...draft, wins: e.target.value })} />
              </label>
              <label><span>Losses</span>
                <input type="number" value={draft.losses} onChange={(e) => setDraft({ ...draft, losses: e.target.value })} />
              </label>
              <label><span>Games</span>
                <input type="number" value={draft.games} onChange={(e) => setDraft({ ...draft, games: e.target.value })} />
              </label>
              <label><span>Streak</span>
                <input type="number" value={draft.streak} onChange={(e) => setDraft({ ...draft, streak: e.target.value })} />
              </label>
            </div>
            <label className="admin-wide"><span>Achievements (comma separated)</span>
              <input value={draft.achievements} onChange={(e) => setDraft({ ...draft, achievements: e.target.value })} />
            </label>

            <div className="actionbar admin-acts">
              <button className="btn primary" disabled={busy}>{busy ? 'Saving…' : 'Save'}</button>
              {confirmBan === openRow.id ? (
                <>
                  <span className="admin-bantext">
                    Really {openRow.is_banned ? 'unban' : 'ban'} {openRow.username}?
                  </span>
                  <button
                    type="button" className="btn danger small" disabled={busy}
                    onClick={() => void toggleBan(openRow)}
                  >
                    Yes
                  </button>
                  <button type="button" className="btn ghost small" onClick={() => setConfirmBan(null)}>
                    No
                  </button>
                </>
              ) : (
                <button
                  type="button" className="btn ghost" disabled={busy}
                  onClick={() => setConfirmBan(openRow.id)}
                >
                  {openRow.is_banned ? 'Unban account' : 'Ban account'}
                </button>
              )}
              {note && <span className="savemark">{note}</span>}
            </div>
            <p className="muted tiny admin-wide">
              Banning revokes access immediately: the account is signed itself
              out within a second or two of this saving (it is watching its own
              row over Realtime), and side_of() stops it acting in any match it
              is already inside before that happens.
            </p>
            {err && <p className="error admin-wide">{err}</p>}
          </form>
        )}
      </div>
    </div>
  )
}
