import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { deleteMyAccount } from '../lib/api'
import { useT } from '../lib/i18n'
import { Modal } from './Modal'

/**
 * Jared: "a button at the end of the options in the settings to delete account, with a confirmation
 * pop up where you'll need to type your current username. It should delete that account from
 * EVERYWHERE ... except the data extracted from their games." Opened from SettingsCard.tsx. The
 * delete button stays disabled until the typed name matches (case does not matter) and the server
 * checks it again, so a stale tab cannot delete the wrong account. See 0246_delete_account.sql.
 */
export function DeleteAccountModal({ onClose }: { onClose: () => void }) {
  const t = useT()
  const [name, setName] = useState<string | null>(null)
  const [typed, setTyped] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    void (async () => {
      const { data: u } = await supabase.auth.getUser()
      if (!u.user) return
      const { data } = await supabase.from('profiles').select('username').eq('id', u.user.id).maybeSingle()
      if (alive) setName((data?.username as string | undefined) ?? null)
    })()
    return () => { alive = false }
  }, [])

  const match = name !== null && typed.trim().toLowerCase() === name.toLowerCase()

  async function go() {
    if (!match || busy) return
    setBusy(true); setErr(null)
    try {
      await deleteMyAccount(typed.trim())
      // The account is gone server-side; this only clears the session this browser is holding.
      await supabase.auth.signOut({ scope: 'local' }).catch(() => undefined)
      window.location.assign(window.location.pathname)
    } catch (e) {
      setErr((e as Error).message)
      setBusy(false)
    }
  }

  return (
    <Modal title={t('account.deleteTitle')} onClose={busy ? () => undefined : onClose}>
      <form className="feedback-form" onSubmit={(e) => { e.preventDefault(); void go() }}>
        <p>{t('account.deleteBody')}</p>
        <p className="muted tiny">{t('account.deleteKept')}</p>
        <label className="feedback-field">
          <span>{t('account.deleteType', { name: name ?? '…' })}</span>
          <input
            type="text" value={typed} onChange={(e) => setTyped(e.target.value)}
            autoComplete="off" autoCapitalize="off" autoCorrect="off" spellCheck={false}
            disabled={busy || name === null} placeholder={name ?? ''}
          />
        </label>
        {err && <p className="error">{err}</p>}
        <div className="actionbar" style={{ justifyContent: 'flex-start' }}>
          <button type="button" className="btn ghost" onClick={onClose} disabled={busy}>
            {t('common.cancel')}
          </button>
          <button type="submit" className="btn danger" disabled={!match || busy}>
            {busy ? t('account.deleting') : t('account.deleteYes')}
          </button>
        </div>
      </form>
    </Modal>
  )
}
