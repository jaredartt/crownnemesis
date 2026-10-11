import { useState } from 'react'
import { reportUser, type ReportReason } from '../lib/api'
import { useT } from '../lib/i18n'
import { Modal } from './Modal'

const REASONS: ReportReason[] = ['cheating', 'offensive_name', 'offensive_profile', 'harassment', 'spam', 'other']

/**
 * Report a player (0217), opened from the Report button on their profile card.
 * The server does the policing: no reporting yourself or a system account, one
 * report per player per day, ten a day in all -- and it says so in a sentence,
 * which is shown as it comes. Reports land in Admin Mode -> Reports.
 */
export function ReportModal({ userId, name, matchId, onClose }: {
  userId: string
  name: string
  matchId?: string | null
  onClose: () => void
}) {
  const t = useT()
  const [reason, setReason] = useState<ReportReason | null>(null)
  const [details, setDetails] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [sent, setSent] = useState(false)

  async function send() {
    if (!reason) return
    setBusy(true); setErr(null)
    try {
      await reportUser(userId, reason, details.trim(), matchId)
      setSent(true)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal title={t('report.title', { name })} onClose={onClose}>
      <div className="feedback-form report-form">
        {sent ? (
          <>
            <p>{t('report.sent')}</p>
            <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
              <button type="button" className="btn primary" onClick={onClose}>{t('report.close')}</button>
            </div>
          </>
        ) : (
          <>
            <fieldset className="report-reasons" disabled={busy}>
              <legend>{t('report.reason')}</legend>
              {REASONS.map((r) => (
                <label key={r} className={reason === r ? 'is-on' : ''}>
                  <input type="radio" name="report-reason" checked={reason === r} onChange={() => setReason(r)} />
                  <span>{t(`report.reason.${r}`)}</span>
                </label>
              ))}
            </fieldset>
            <label className="feedback-field">
              <span>{t('report.details')}</span>
              <textarea value={details} onChange={(e) => setDetails(e.target.value)}
                        maxLength={500} rows={3} disabled={busy} />
            </label>
            <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
              <button type="button" className="btn primary" disabled={busy || !reason} onClick={() => void send()}>
                {busy ? t('report.sending') : t('report.send')}
              </button>
            </div>
            {err && <p className="error tiny">{err}</p>}
          </>
        )}
      </div>
    </Modal>
  )
}
