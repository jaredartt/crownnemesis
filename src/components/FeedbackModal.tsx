import { useState } from 'react'
import { submitFeedback } from '../lib/api'
import { useT } from '../lib/i18n'
import { Modal } from './Modal'

type Kind = 'feedback' | 'bug'

/**
 * Jared: "create a button inside settings to send feedback or report a
 * bug." Opened from SettingsCard.tsx, same nested-Modal shape PlayerCard
 * already opens on top of Friends' own Modal. Same three-state shape as
 * App.tsx's own BanAppealPanel (a kind toggle instead of that screen's
 * single always-bug-report case) -- a still-signed-in account calling a
 * SECURITY DEFINER RPC keyed off auth.uid(), nothing else needed client
 * side. See 0169_admin_activity_and_feedback.sql / submit_feedback().
 */
export function FeedbackModal({ onClose }: { onClose: () => void }) {
  const t = useT()
  const [kind, setKind] = useState<Kind>('feedback')
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [sent, setSent] = useState(false)

  async function submit() {
    setBusy(true); setErr(null)
    try {
      await submitFeedback(kind, message)
      setSent(true)
    } catch (e) {
      setErr((e as Error).message.replace(/^.*?:\s*/, ''))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal title={t('feedback.title')} onClose={onClose}>
      <div className="feedback-form">
        {sent ? (
          <>
            <p>{t('feedback.sentNote')}</p>
            <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
              <button type="button" className="btn primary" onClick={onClose}>
                {t('common.close')}
              </button>
            </div>
          </>
        ) : (
          <>
            <div className="seg" role="radiogroup" aria-label={t('feedback.title')}>
              {([['feedback', 'feedback.kindFeedback'], ['bug', 'feedback.kindBug']] as [Kind, string][]).map(
                ([v, key]) => (
                  <button
                    key={v} type="button" role="radio" aria-checked={kind === v}
                    className={kind === v ? 'is-on' : ''} onClick={() => setKind(v)}
                  >
                    {t(key)}
                  </button>
                ),
              )}
            </div>
            <label className="feedback-field">
              <span>{t('feedback.label')}</span>
              <textarea
                value={message} onChange={(e) => setMessage(e.target.value)}
                maxLength={4000} rows={5} disabled={busy}
                placeholder={t(kind === 'bug' ? 'feedback.placeholderBug' : 'feedback.placeholderFeedback')}
              />
            </label>
            <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
              <button
                type="button" className="btn primary" disabled={busy || !message.trim()}
                onClick={() => void submit()}
              >
                {busy ? t('feedback.sending') : t('feedback.send')}
              </button>
            </div>
            {err && <p className="error tiny">{err}</p>}
          </>
        )}
      </div>
    </Modal>
  )
}
